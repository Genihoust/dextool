/// Written in the D programming language.
/// @date 2014, Joakim Brännström
/// @copyright MIT License
/// @author Joakim Brännström (joakim.brannstrom@gmx.com)
module app_main;
import std.conv;
import std.stdio;
import std.string;
import std.experimental.logger;

import clang.c.index;
import clang.c.cxstring;

auto _getTokenKindSpelling(CXTokenKind kind) {
    with (CXTokenKind) switch (kind) {
    case CXToken_Punctuation:
        return "Punctuation";
        case CXToken_Keyword:
        return "Keyword";
        case CXToken_Identifier:
        return "Identifier";
        case CXToken_Literal:
        return "Literal";
        case CXToken_Comment:
        return "Comment";
        default:
        return "Unknown";
    }
}

void show_all_tokens(ref CXTranslationUnit tu, CXToken* tokens, uint numTokens) {
    writeln("=== show tokens ===");
    writef("NumTokens: %d\n", numTokens);
    for (auto i = 0U; i < numTokens; i++) {
        CXToken* token = &tokens[i];
        CXTokenKind kind = clang_getTokenKind(*token);
        CXString spell = clang_getTokenSpelling(tu, *token);
        CXSourceLocation loc = clang_getTokenLocation(tu, *token);

        CXFile file;
        uint line, column, offset;
        clang_getFileLocation(loc, &file, &line, &column, &offset);
        CXString fileName = clang_getFileName(file);

        writef("Token: %d\n", i);
        writef(" Text: %s\n", toD(spell));
        writef(" Kind: %s\n", _getTokenKindSpelling(kind));
        writef(" Location: %s:%d:%d:%d\n", toD(fileName), line, column,
            offset);
        writef("\n");

        clang_disposeString(fileName);
    }
}

string toD(CXString cxString) {
    auto cstr = clang_getCString(cxString);
    auto str = to!(string)(cstr).idup;
    clang_disposeString(cxString);

    return str;
}

U* toCArray(U, T)(T[] arr) {
    if (!arr)
        return null;

    U[] cArr;
    cArr.reserve(arr.length);

    foreach (e; arr)
        cArr ~= e.cx;

    return cArr.ptr;
}

immutable(char*)* strToCArray(string[] arr) {
    if (!arr)
        return null;

    immutable(char*)[] cArr;
    cArr.reserve(arr.length);

    foreach (str; arr)
        cArr ~= str.toStringz;

    return cArr.ptr;
}

auto get_filesize(in string fileName) {
    import std.file;

    return getSize(fileName);
}

CXSourceRange get_filerange(ref CXTranslationUnit tu, in string filename) {
    CXFile file = clang_getFile(tu, filename.toStringz);
    uint fileSize = cast(uint) get_filesize(filename);

    // get top/last location of the file
    CXSourceLocation topLoc = clang_getLocationForOffset(tu, file, 0);
    CXSourceLocation lastLoc = clang_getLocationForOffset(tu, file, fileSize);
    if (clang_equalLocations(topLoc, clang_getNullLocation())
            || clang_equalLocations(lastLoc, clang_getNullLocation())) {
        writef("cannot retrieve location\n");
        throw new Exception("location");
    }

    // make a range from locations
    CXSourceRange range = clang_getRange(topLoc, lastLoc);
    if (clang_Range_isNull(range)) {
        writef("cannot retrieve range\n");
        throw new Exception("range");
    }

    return range;
}

void show_clang_version() {
    CXString version_ = clang_getClangVersion();
    writef("%s\n", toD(version_));
}

int rmain(string[] args) {
    if (args.length < 2) {
        write("Tokenize filename [options ...]\n");
        return 1;
    }

    show_clang_version();
    auto filename = args[1];

    // create index w/ excludeDeclsFromPCH = 1, displayDiagnostics=1.
    CXIndex index = clang_createIndex(1, 1);

    // create Translation Unit
    CXTranslationUnit tu = clang_parseTranslationUnit(index, filename.toStringz,
        null, 0, null, 0, 0);
    if (tu == null) {
        writef("Cannot parse translation unit\n");
        return 1;
    }

    // get CXSouceRange of the file
    CXSourceRange range = get_filerange(tu, filename);

    // tokenize in the range
    CXToken* tokens;
    uint numTokens;
    clang_tokenize(tu, range, &tokens, &numTokens);

    // show tokens
    show_all_tokens(tu, tokens, numTokens);

    clang_disposeTokens(tu, tokens, numTokens);
    clang_disposeTranslationUnit(tu);
    clang_disposeIndex(index);

    return 0;
}
