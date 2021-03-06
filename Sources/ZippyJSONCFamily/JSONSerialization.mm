//Copyright (c) 2018 Michael Eisel. All rights reserved.

// NOTE: ARC is disabled for this file

#import "simdjson.h"
#import "JSONSerialization_Private.h"
#import "JSONSerialization.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <math.h>
#import <string.h>
#import <atomic>
#import <mutex>
#import <typeinfo>
#import <deque>
#import <dispatch/dispatch.h>

using namespace simdjson;

static inline char JNTStringPop(char **string) {
    char c = **string;
    (*string)++;
    return c;
}

typedef simdjson::ParsedJson::iterator Iterator;

BOOL JNTHasVectorExtensions() {
#ifdef __SSE4_2__
  return true;
#else
  return false;
#endif
}

struct JNTContext;

struct JNTDecoder {
    Iterator iterator;
    JNTContext *context;
    JNTDecoder(Iterator iterator, JNTContext *context) : iterator(iterator), context(context) {
    }
};

struct JNTDecodingError {
    std::string description = "";
    JNTDecodingErrorType type = JNTDecodingErrorTypeNone;
    DecoderPointer value = NULL;
    std::string key = "";
    JNTDecodingError() {
    }
    JNTDecodingError(std::string description, JNTDecodingErrorType type, DecoderPointer value, std::string key) : description(description), type(type), value(value), key(key) {
    }
};

struct JNTContext { // static for classes?
public:
    ParsedJson parser;
    JNTDecodingError error;
    std::string snakeCaseBuffer;

    std::string posInfString;
    std::string negInfString;
    std::string nanString;

    const char *originalString;
    uint32_t originalStringLength;

    JNTContext(const char *originalString, uint32_t originalStringLength, std::string posInfString, std::string negInfString, std::string nanString) : originalString(originalString), originalStringLength(originalStringLength), posInfString(posInfString), negInfString(negInfString), nanString(nanString) {
    }
};

void JNTClearError(ContextPointer context) {
    context->error = JNTDecodingError();
}

bool JNTErrorDidOccur(ContextPointer context) {
    return context->error.type != JNTDecodingErrorTypeNone;
}

bool JNTDocumentErrorDidOccur(DecoderPointer decoder) {
    return JNTErrorDidOccur(decoder->context);
}

ContextPointer JNTGetContext(DecoderPointer decoder) {
    return decoder->context;
}

void JNTProcessError(ContextPointer context, void (^block)(const char *description, JNTDecodingErrorType type, DecoderPointer value, const char *key)) {
    JNTDecodingError &error = context->error;
    block(error.description.c_str(), error.type, error.value, error.key.c_str());
}

typedef JNTDecoder *DecoderPointer;

static const char *JNTStringForType(uint8_t type) {
    switch (type) {
        case 'n':
            return "null";
        case 't':
        case 'f':
            return "Bool";
        case '{':
            return "Dictionary";
        case '[':
            return "Array";
        case '"':
            return "String";
        case 'd':
        case 'l':
            return "Number";
    }
    return "?";
}

static inline void JNTSetError(std::string description, JNTDecodingErrorType type, JNTContext *context, JNTDecoder *decoder, std::string key) {
    if (context->error.type != JNTDecodingErrorTypeNone) {
        return;
    }
    JNTDecoder *value = decoder ? new JNTDecoder(*decoder) : NULL;
    context->error = JNTDecodingError(description, type, value, key);
}

static void JNTHandleJSONParsingFailed(int res, JNTContext *context) {
    std::ostringstream oss;
    oss << "The given data was not valid JSON. Error: " << simdjson::errorMsg(res);
    JNTSetError(oss.str(), JNTDecodingErrorTypeJSONParsingFailed, context, NULL, "");
}

static void JNTHandleWrongType(JNTDecoder *decoder, uint8_t type, const char *expectedType) {
    JNTDecodingErrorType errorType = type == 'n' ? JNTDecodingErrorTypeValueDoesNotExist : JNTDecodingErrorTypeWrongType;
    std::ostringstream oss;
    oss << "Expected to decode " << expectedType << " but found " << JNTStringForType(type) << " instead.";
    JNTSetError(oss.str(), errorType, decoder->context, decoder, "");
}

static void JNTHandleMemberDoesNotExist(JNTDecoder *decoder, const char *key) {
    std::ostringstream oss;
    oss << "No value associated with " << key << ".";
    JNTSetError(oss.str(), JNTDecodingErrorTypeKeyDoesNotExist, decoder->context, decoder, key);
}

template <typename T>
static void JNTHandleNumberDoesNotFit(JNTDecoder *decoder, T number, const char *type) {
    //char *description = nullptr;
    NS_VALID_UNTIL_END_OF_SCOPE NSString *string = [@(number) description];
    std::ostringstream oss;
    oss << "Parsed JSON number " << string.UTF8String << " does not fit.";
    std::string description = oss.str();
    JNTSetError(description, JNTDecodingErrorTypeNumberDoesNotFit, decoder->context, decoder, "");
}

static inline bool JNTIsLower(char c) {
    return 'a' <= c && c <= 'z';
}

static inline bool JNTIsUpper(char c) {
    return 'A' <= c && c <= 'Z';
}

static inline char JNTToUpper(char c) {
    return JNTIsLower(c) ? c + ('A' - 'a') : c;
}

static inline char JNTToLower(char c) {
    return JNTIsUpper(c) ? c + ('a' - 'A') : c;
}

static inline uint32_t JNTReplaceSnakeWithCamel(std::string &buffer, char *string) {
    buffer.erase();
    char *end = string + strlen(string);
    char *currString = string;
    while (currString < end) {
        if (*currString != '_') {
            break;
        }
        buffer.push_back('_');
        currString++;
    }
    if (currString == end) {
        return (uint32_t)(end - string);
    }
    char *originalEnd = end;
    end--;
    while (*end == '_') {
        end--;
    }
    end++;
    bool didHitUnderscore = false;
    size_t leadingUnderscoreCount = currString - string;
    while (currString < end) {
        char first = JNTStringPop(&currString);
        buffer.push_back(JNTToUpper(first));
        while (currString < end && *currString != '_') {
            char c = JNTStringPop(&currString);
            buffer.push_back(JNTToLower(c));
        }
        while (currString < end && *currString == '_') {
            didHitUnderscore = true;
            currString++;
        }
    }
    if (!didHitUnderscore) {
        return (uint32_t)(originalEnd - string);
    }
    buffer[leadingUnderscoreCount] = JNTToLower(buffer[leadingUnderscoreCount]); // If the first got capitalized
    for (NSInteger i = 0; i < originalEnd - end; i++) {
        buffer.push_back('_');
    }
    memcpy(string, buffer.c_str(), buffer.size() + 1);
    uint32_t size = (uint32_t)buffer.size();
    return size;
}

void JNTConvertSnakeToCamel(DecoderPointer decoder) {
    do {
        if (!decoder->iterator.is_string()) {
            return;
        }
        uint32_t newLength = JNTReplaceSnakeWithCamel(decoder->context->snakeCaseBuffer, (char *)decoder->iterator.get_string());
        decoder->iterator.set_string_length(newLength);
        decoder->iterator.move_to_value();
    } while (decoder->iterator.next());
}

static inline char JNTChecker(const char *s) {
    char has = '\0';
    while (*s != '\0') {
        has |= *s;
        s++;
    }
    return has;
}

static inline char JNTCheckHelper(Iterator& i) {
    char has = '\0';
    if (i.is_object()) {
        if (!i.down()) {
            return has;
        }
        do {
            has |= JNTChecker(i.get_string());
            i.move_to_value();
            if (i.is_object_or_array()) {
                has |= JNTCheckHelper(i);
            }
        } while (i.next());
    } else if (i.is_array()) {
        if (!i.down()) {
            return has;
        }
        do {
            if (i.is_object_or_array()) {
                has |= JNTCheckHelper(i);
            }
        } while (i.next());
    }
    return has;
}

// Check if there are any non-ASCII chars in the dictionary keys
static inline bool JNTCheck(Iterator i) {
    return (JNTCheckHelper(i) & 0x80) != '\0';
}

ContextPointer JNTCreateContext(const char *originalString, uint32_t originalStringLength, const char *negInfString, const char *posInfString, const char *nanString) {
    return new JNTContext(originalString, originalStringLength, std::string(posInfString), std::string(negInfString), std::string(nanString));
}

static uint64_t kDataLimit = (1ULL << 32) - 1;

DecoderPointer JNTDocumentFromJSON(ContextPointer context, const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing) {
    if (length > kDataLimit) {
        *retryReason = "The length of the JSON data is too long (see kDataLimit for the max)";
    }
    context->parser.full_precision_float_parsing = fullPrecisionFloatParsing;
    simdjson::padded_string ps = simdjson::padded_string((char *)data, length);
    NSInteger capacity = length ?: 1;
    bool success = context->parser.allocateCapacity(capacity);
    assert(success);
    const int res = json_parse(ps, context->parser);
    if (res != 0) {
        if (res != NUMBER_ERROR) { // retry number errors
            JNTHandleJSONParsingFailed(res, context);
        } else {
            *retryReason = "Either the JSON is malformed, e.g. passing a number as the root object, or an integer was too large (couldn't fit in a 64-bit signed integer)";
        }
        return NULL;
    }
    Iterator iterator = Iterator(context->parser);
    if (JNTCheck(iterator)) {
        *retryReason = "One or more keys had non-ASCII characters";
        return NULL;
    } else {
        return new JNTDecoder(iterator, context);
    }
}

void JNTReleaseContext(JNTContext *context) {
    delete context;
}

BOOL JNTDocumentContains(DecoderPointer decoder, const char *key, bool isEmpty) {
    if (isEmpty) {
        return false;
    }
    decoder->iterator.prev_string();
    return decoder->iterator.search_for_key(key, strlen(key));
}

namespace TypeChecker {
    bool Double(Iterator *value) {
        return value->is_double();
    }
    bool UInt64(Iterator *value) {
        return value->is_integer();
    }
    bool Int64(Iterator *value) {
        return value->is_integer();
    }
    bool String(Iterator *value) {
        return value->is_string();
    }
    bool Bool(Iterator *value) {
        return value->is_true() || value->is_false();
    }
}

namespace Converter {
    double Double(Iterator *value) {
        return value->get_double();
    }
    uint64_t UInt64(Iterator *value) {
        return value->get_integer();
    }
    int64_t Int64(Iterator *value) {
        return value->get_integer();
    }
    const char *String(Iterator *value) {
        return value->get_string();
    }
    bool Bool(Iterator *value) {
        return value->is_true();
    }
}

template <typename T, typename U, bool (*TypeCheck)(Iterator *), U (*Convert)(Iterator *)>
static inline T JNTDocumentDecode(DecoderPointer decoder) {
    Iterator *iterator = &decoder->iterator;
    if (unlikely(!TypeCheck(iterator))) {
        JNTHandleWrongType(decoder, decoder->iterator.get_type(), typeid(T).name());
        return 0;
    }
    U number = Convert(iterator);
    T result = (T)number;
    if (unlikely(number != result)) {
        JNTHandleNumberDoesNotFit(decoder, number, typeid(T).name());
        return 0;
    }
    return result;
}

NSInteger JNTDocumentGetArrayCount(DecoderPointer decoder) {
    NSInteger count = 1;
    NSInteger oldLocation = decoder->iterator.get_tape_location();
    decoder->iterator.to_start_scope();
    assert(decoder->iterator.get_tape_location() == oldLocation);
    while (decoder->iterator.next()) {
        count++;
    }
    decoder->iterator.to_start_scope();
    return count;
}

void JNTDocumentNextArrayElement(DecoderPointer decoder, bool *isAtEnd) {
    if (*isAtEnd) {
        return;
    }
    *isAtEnd = !decoder->iterator.next();
}

BOOL JNTDocumentDecodeNil(DecoderPointer decoder) {
    return decoder->iterator.is_null();
}

double JNTDocumentDecode__Double(DecoderPointer decoder) {
    if (TypeChecker::Double(&decoder->iterator)) {
        return Converter::Double(&decoder->iterator);
    } else if (decoder->iterator.is_integer()){
        return (double)decoder->iterator.get_integer();
    } else {
        if (decoder->iterator.is_string()) {
            const char *string = decoder->iterator.get_string();
            if (strcmp(string, decoder->context->posInfString.c_str()) == 0) {
                return INFINITY;
            } else if (strcmp(string, decoder->context->negInfString.c_str()) == 0) {
                return -INFINITY;
            } else if (strcmp(string, decoder->context->nanString.c_str()) == 0) {
                return NAN;
            }
        }
        JNTHandleWrongType(decoder, decoder->iterator.get_type(), "double/float");
        return 0;
    }
}

float JNTDocumentDecode__Float(DecoderPointer decoder) {
    return (float)JNTDocumentDecode__Double(decoder);
}

static bool JNTIteratorsEqual(Iterator *i1, Iterator *i2) {
    return i1->get_tape_location() == i2->get_tape_location();
}

NSMutableArray <id> *JNTDocumentCodingPathHelper(Iterator iterator, Iterator *targetIterator) {
    if (iterator.is_array()) {
        if (iterator.down()) {
            NSInteger i = 0;
            do {
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(i)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(i) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    } else if (iterator.is_object()) {
        if (iterator.down()) {
            do {
                const char *key = iterator.get_string();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                }
                iterator.move_to_value();
                if (JNTIteratorsEqual(&iterator, targetIterator)) {
                    return [@[@(key)] mutableCopy];
                } else if (iterator.is_object_or_array()) {
                    NSMutableArray *codingPath = JNTDocumentCodingPathHelper(iterator, targetIterator);
                    if (codingPath) {
                        [codingPath insertObject:@(key) atIndex:0];
                        return codingPath;
                    }
                }
            } while (iterator.next());
        }
    }
    return nil;
}

NSArray <id> *JNTDocumentCodingPath(DecoderPointer targetDecoder) {
    Iterator iterator = Iterator(targetDecoder->context->parser);
    if (JNTIteratorsEqual(&iterator, &targetDecoder->iterator)) {
        return @[];
    }
    NSMutableArray *array = JNTDocumentCodingPathHelper(iterator, &targetDecoder->iterator);
    return array ? [array copy] : @[];
}

NSArray <NSString *> *JNTDocumentAllKeys(DecoderPointer decoder, bool isEmpty) {
    if (isEmpty) {
        return @[];
    }
    NSMutableArray <NSString *>*keys = [NSMutableArray array];
    decoder->iterator.to_start_scope();
    do {
        if (!decoder->iterator.is_string()) {
            break;
        }
        [keys addObject:@(decoder->iterator.get_string())];
        decoder->iterator.move_to_value();
    } while (decoder->iterator.next());
    return [keys copy];
}

void JNTDocumentForAllKeyValuePairs(DecoderPointer decoderOriginal, void (^callback)(const char *key, DecoderPointer decoder)) {
    // Make a copy of the iterator
    Iterator iterator = decoderOriginal->iterator;
    if (iterator.get_type() != '{') {
        JNTHandleWrongType(decoderOriginal, iterator.get_type(), "{");
        return;
    }
    if (!iterator.down()) {
        return;
    }
    do {
        const char *key = iterator.get_string();
        iterator.move_to_value();
        JNTDecoder decoder = JNTDecoder(iterator, decoderOriginal->context);
        callback(key, &decoder);
    } while (iterator.next());
}

void JNTReleaseValue(DecoderPointer decoder) {
    delete decoder;
}

DecoderPointer JNTDocumentCreateCopy(DecoderPointer decoder) {
    return new JNTDecoder(decoder->iterator, decoder->context);
}

DecoderPointer JNTDocumentEnterStructureAndReturnCopy(DecoderPointer decoder, bool *isEmpty) {
    DecoderPointer copy = JNTDocumentCreateCopy(decoder);
    *isEmpty = !copy->iterator.down();
    return copy;
}

__attribute__((always_inline)) DecoderPointer JNTDocumentFetchValue(DecoderPointer decoder, const char *key, bool isEmpty) {
    if (isEmpty) {
        JNTHandleMemberDoesNotExist(decoder, key);
        return decoder;
    }
    decoder->iterator.prev_string();
    if (!decoder->iterator.search_for_key(key, strlen(key))) {
        JNTHandleMemberDoesNotExist(decoder, key);
    }
    return decoder;
}

bool JNTDocumentValueIsDictionary(DecoderPointer decoder) {
    return decoder->iterator.is_object();
}

bool JNTDocumentValueIsArray(DecoderPointer decoder) {
    return decoder->iterator.is_array();
}

// todo: add 64-bit uint support when that comes around
bool JNTDocumentValueIsInteger(DecoderPointer decoder) {
    return decoder->iterator.is_integer();
}

bool JNTDocumentValueIsDouble(DecoderPointer decoder) {
    return decoder->iterator.is_double();
}

bool JNTIsNumericCharacter(char c) {
    return c == 'e' || c == 'E' || c == '-' || c == '.' || isnumber(c);
}

const char *JNTDocumentDecode__DecimalString(DecoderPointer decoder, int32_t *outLength) {
    *outLength = 0; // Make sure it doesn't get left uninitialized
    // todo: use uint64_t everywhere here if we ever support > 4GB files
    uint32_t location = (uint32_t)decoder->iterator.get_tape_location();
    uint32_t offset = decoder->context->parser.offsetForLocation(location);
    const char *dataStart = decoder->context->originalString;
    const char *dataEnd = dataStart + decoder->context->originalStringLength;
    const char *string = dataStart + offset;
    if (string >= dataEnd) {
        return NULL;
    }
    int32_t length = 0;
    // simdjson has already done validation on the numbers, so just try to find the end of the number.
    // we could also use the structural character idxs, probably
    while (JNTIsNumericCharacter(string[length]) && string + length < dataEnd) {
        length++;
    }
    *outLength = length;
    return string;
}

#define DECODE(A, B, C, D) DECODE_NAMED(A, B, C, D, A)

#define DECODE_NAMED(A, B, C, D, E) \
A JNTDocumentDecode__##E(DecoderPointer decoder) { \
    return JNTDocumentDecode<A, B, TypeChecker::C, Converter::D>(decoder); \
}
ENUMERATE(DECODE);
