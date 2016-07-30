// Written in the D programming language.
/**
Date: 2015-2016, Joakim Brännström
License: MPL-2, Mozilla Public License 2.0
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module plugin.frontend.ctestdouble;

import logger = std.experimental.logger;

import application.types;
import application.utility;
import application.compilation_db;

import plugin.types;
import plugin.backend.cvariant : Controller, Parameters, Products;

auto runPlugin(CliOption opt, CliArgs args) {
    import std.typecons : TypedefType;
    import docopt;

    auto parsed = docopt.docoptParse(cast(TypedefType!CliOption) opt,
            cast(TypedefType!CliArgs) args);

    string[] cflags;
    if (parsed["--"].isTrue) {
        cflags = parsed["CFLAGS"].asList;
    }

    import plugin.docopt_util;

    printArgs(parsed);

    auto variant = CTestDoubleVariant.makeVariant(parsed);

    CompileCommandDB compile_db;
    if (!parsed["--compile-db"].isEmpty) {
        compile_db = parsed["--compile-db"].asList.fromArgCompileDb;
    }

    return genCstub(variant, cflags, compile_db, InFiles(parsed["--in"].asList));
}

// dfmt off
static auto ctestdouble_opt = CliOptionParts(
    "usage:
 dextool ctestdouble [options] [--compile-db=...] [--file-exclude=...] [--td-include=...] --in=... [--] [CFLAGS...]
 dextool ctestdouble [options] [--compile-db=...] [--file-restrict=...] [--td-include=...] --in=... [--] [CFLAGS...]",
    // -------------
    " --out=dir          directory for generated files [default: ./]
 --main=name        Used as part of interface, namespace etc [default: TestDouble]
 --main-fname=n     Used as part of filename for generated files [default: test_double]
 --prefix=p         Prefix used when generating test artifacts [default: Test_]
 --strip-incl=r     A regexp used to strip the include paths
 --gmock            Generate a gmock implementation of test double interface
 --gen-pre-incl     Generate a pre include header file if it doesn't exist and use it
 --gen-post-incl    Generate a post include header file if it doesn't exist and use it
 --loc-as-comment   Generate a comment containing the location the symbol was derived from.
                    Makes it easier to correctly define excludes/restricts",
    // -------------
"others:
 --in=              Input files to parse
 --compile-db=      Retrieve compilation parameters from the file
 --file-exclude=    Exclude files from generation matching the regex
 --file-restrict=   Restrict the scope of the test double to those files
                    matching the regex
 --td-include=      User supplied includes used instead of those found
"
);
// dfmt on

/** Test double generation of C code.
 *
 * TODO Describe the options.
 */
class CTestDoubleVariant : Controller, Parameters, Products {
    import std.regex : regex, Regex;
    import std.typecons : Tuple, Flag;
    import docopt : ArgValue;
    import application.types : StubPrefix, FileName, DirName;
    import application.utility;
    import dsrcgen.cpp;

    alias FileData = Tuple!(FileName, "filename", string, "data");

    static const hdrExt = ".hpp";
    static const implExt = ".cpp";

    immutable StubPrefix prefix;
    immutable StubPrefix file_prefix;

    immutable DirName output_dir;
    immutable FileName main_file_hdr;
    immutable FileName main_file_impl;
    immutable FileName main_file_globals;
    immutable FileName gmock_file;
    immutable FileName pre_incl_file;
    immutable FileName post_incl_file;

    immutable MainName main_name;
    immutable MainNs main_ns;
    immutable MainInterface main_if;
    immutable Flag!"Gmock" gmock;
    immutable Flag!"PreInclude" pre_incl;
    immutable Flag!"PostInclude" post_incl;
    immutable Flag!"locationAsComment" loc_as_comment;

    Regex!char[] exclude;
    Regex!char[] restrict;

    /// Data produced by the generatore intented to be written to specified file.
    FileData[] file_data;

    private TestDoubleIncludes td_includes;

    static auto makeVariant(ref ArgValue[string] parsed) {
        import std.array : array;
        import std.algorithm : map;

        Regex!char[] exclude = parsed["--file-exclude"].asList.map!(a => regex(a)).array();
        Regex!char[] restrict = parsed["--file-restrict"].asList.map!(a => regex(a)).array();
        Regex!char strip_incl;
        auto gmock = cast(Flag!"Gmock") parsed["--gmock"].isTrue;
        auto pre_incl = cast(Flag!"PreInclude") parsed["--gen-pre-incl"].isTrue;
        auto post_incl = cast(Flag!"PostInclude") parsed["--gen-post-incl"].isTrue;
        auto loc_as_comment = cast(Flag!"locationAsComment") parsed["--loc-as-comment"].isTrue;

        if (!parsed["--strip-incl"].isNull) {
            string strip_incl_user = parsed["--strip-incl"].toString;
            strip_incl = regex(strip_incl_user);
            logger.trace("User supplied regex via --strip-incl: ", strip_incl_user);
        } else {
            logger.trace("Using default regex to strip include path (basename)");
            strip_incl = regex(r".*/(.*)");
        }

        auto variant = new CTestDoubleVariant(StubPrefix(parsed["--prefix"].toString), StubPrefix("Not used"),
                MainFileName(parsed["--main-fname"].toString), MainName(parsed["--main"].toString),
                DirName(parsed["--out"].toString), gmock, pre_incl, post_incl,
                loc_as_comment, strip_incl);

        if (!parsed["--td-include"].isEmpty) {
            variant.forceIncludes(parsed["--td-include"].asList);
        }

        // optional parts
        variant.exclude = exclude;
        variant.restrict = restrict;

        return variant;
    }

    /** Design of c'tor.
     *
     * The c'tor has as paramters all the required configuration data.
     * Assignment of members are used for optional configuration.
     *
     * Follows the design pattern "correct by construction".
     *
     * TODO document the parameters.
     */
    this(StubPrefix prefix, StubPrefix file_prefix, MainFileName main_fname, MainName main_name, DirName output_dir,
            Flag!"Gmock" gmock, Flag!"PreInclude" pre_incl, Flag!"PostInclude" post_incl,
            Flag!"locationAsComment" loc_as_comment, Regex!char strip_incl) {
        this.prefix = prefix;
        this.file_prefix = file_prefix;
        this.main_name = main_name;
        this.main_ns = MainNs(cast(string) main_name);
        this.main_if = MainInterface("I_" ~ cast(string) main_name);
        this.output_dir = output_dir;
        this.gmock = gmock;
        this.pre_incl = pre_incl;
        this.post_incl = post_incl;
        this.loc_as_comment = loc_as_comment;
        this.td_includes = TestDoubleIncludes(strip_incl);

        import std.path : baseName, buildPath, stripExtension;

        string base_filename = cast(string) main_fname;

        this.main_file_hdr = FileName(buildPath(cast(string) output_dir, base_filename ~ hdrExt));
        this.main_file_impl = FileName(buildPath(cast(string) output_dir, base_filename ~ implExt));
        this.main_file_globals = FileName(buildPath(cast(string) output_dir,
                base_filename ~ "_global" ~ implExt));
        this.gmock_file = FileName(buildPath(cast(string) output_dir,
                base_filename ~ "_gmock" ~ hdrExt));
        this.pre_incl_file = FileName(buildPath(cast(string) output_dir,
                base_filename ~ "_pre_includes" ~ hdrExt));
        this.post_incl_file = FileName(buildPath(cast(string) output_dir,
                base_filename ~ "_post_includes" ~ hdrExt));
    }

    /// Force the includes to be those supplied by the user.
    void forceIncludes(string[] incls) {
        td_includes.forceIncludes(incls);
    }

    // -- Controller --

    bool doFile(in string filename, in string info) {
        import std.algorithm : canFind;
        import std.regex : matchFirst;

        bool r = true;

        // docopt blocks during parsing so both restrict and exclude cannot be
        // set at the same time.
        if (restrict.length > 0) {
            r = canFind!((a) {
                auto m = matchFirst(filename, a);
                return !m.empty && m.pre.length == 0 && m.post.length == 0;
            })(restrict);
            debug {
                logger.tracef(!r, "--file-restrict skipping %s", info);
            }
        } else if (exclude.length > 0) {
            r = !canFind!((a) {
                auto m = matchFirst(filename, a);
                return !m.empty && m.pre.length == 0 && m.post.length == 0;
            })(exclude);
            debug {
                logger.tracef(!r, "--file-exclude skipping %s", info);
            }
        }

        return r;
    }

    bool doGoogleMock() {
        return gmock;
    }

    bool doPreIncludes() {
        import std.path : exists;

        return pre_incl && !exists(cast(string) pre_incl_file);
    }

    bool doIncludeOfPreIncludes() {
        return pre_incl;
    }

    bool doPostIncludes() {
        import std.path : exists;

        return post_incl && !exists(cast(string) post_incl_file);
    }

    bool doIncludeOfPostIncludes() {
        return post_incl;
    }

    bool doLocationAsComment() {
        return loc_as_comment;
    }

    // -- Parameters --

    FileName[] getIncludes() {
        td_includes.doStrip();
        return td_includes.incls;
    }

    DirName getOutputDirectory() {
        return output_dir;
    }

    Parameters.Files getFiles() {
        return Parameters.Files(main_file_hdr, main_file_impl,
                main_file_globals, gmock_file, pre_incl_file, post_incl_file);
    }

    MainName getMainName() {
        return main_name;
    }

    MainNs getMainNs() {
        return main_ns;
    }

    MainInterface getMainInterface() {
        return main_if;
    }

    StubPrefix getFilePrefix() {
        return file_prefix;
    }

    StubPrefix getArtifactPrefix() {
        return prefix;
    }

    // -- Products --

    void putFile(FileName fname, CppHModule hdr_data) {
        file_data ~= FileData(fname, hdr_data.render());
    }

    void putFile(FileName fname, CppModule impl_data) {
        file_data ~= FileData(fname, impl_data.render());
    }

    void putLocation(FileName fname, LocationType type) {
        td_includes.put(fname, type);
    }
}

/// TODO refactor, doing too many things.
ExitStatusType genCstub(CTestDoubleVariant variant, in string[] in_cflags,
        CompileCommandDB compile_db, InFiles in_files) {
    import std.conv : text;
    import std.path : buildNormalizedPath, asAbsolutePath;
    import std.typecons : TypedefType;
    import plugin.backend.cvariant : CVisitor, Generator;

    const auto user_cflags = prependDefaultFlags(in_cflags, "-xc");

    auto generator = Generator(variant, variant, variant);
    const auto total_files = in_files.length;
    auto visitor = new CVisitor(variant, variant);

    foreach (idx, in_file; (cast(TypedefType!InFiles) in_files)) {
        logger.infof("File %d/%d ", idx + 1, total_files);
        string[] use_cflags;
        string abs_in_file;

        // TODO duplicate code in c, c++ and plantuml. Fix it.
        if (compile_db.length > 0) {
            auto db_search_result = compile_db.appendOrError(user_cflags, in_file);
            if (db_search_result.isNull) {
                return ExitStatusType.Errors;
            }
            use_cflags = db_search_result.get.cflags;
            abs_in_file = db_search_result.get.absoluteFile;
        } else {
            use_cflags = user_cflags.dup;
            abs_in_file = buildNormalizedPath(in_file).asAbsolutePath.text;
        }

        if (analyzeFile(abs_in_file, use_cflags, visitor) == ExitStatusType.Errors) {
            return ExitStatusType.Errors;
        }
    }

    // Analyse and generate test double
    generator.analyse(visitor.root, visitor.container);
    generator.process(visitor.container);

    return writeFileData(variant.file_data);
}
