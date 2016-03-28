// Written in the D programming language.
/**
Copyright: Copyright (c) 2016, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.
*/
module plugin.backend.plantuml;

import std.typecons : Typedef, Tuple, Flag, Yes, No;
import logger = std.experimental.logger;

import dsrcgen.plantuml;

import application.types;
import cpptooling.data.symbol.types : FullyQualifiedNameType;

version (unittest) {
    import test.helpers : shouldEqualPretty;
    import unit_threaded : Name, shouldEqual;
} else {
    struct Name {
        string name_;
    }
}

/** Control various aspectes of the analyze and generation like what nodes to
 * process.
 */
@safe interface Controller {
    /// Query the controller with the filename of the AST node for a decision
    /// if it shall be processed.
    bool doFile(in string filename, in string info);

    /** Determine by checking the filesystem if a templated PREFIX_style file shall be created.
     *
     * Create it with a minimal style.
     * Currently just the direction but may change in the future.
     */
    Flag!"genStyleInclFile" genStyleInclFile();

    /// Strip the filename according to user regex.
    FileName doComponentNameStrip(FileName fname);
}

/// Parameters used during generation.
/// Important aspact that they do NOT change, therefore it is pure.
@safe pure const interface Parameters {
    import std.typecons : Tuple, Flag;

    alias Files = Tuple!(FileName, "classes", FileName, "components", FileName,
            "styleIncl", FileName, "styleOutput");

    /// Output directory to store files in.
    DirName getOutputDirectory();

    /// Files to write generated diagram data to.
    Files getFiles();

    /// Name affecting filenames.
    FilePrefix getFilePrefix();

    /// If class methods should be part of the generated class diagrams.
    Flag!"genClassMethod" genClassMethod();

    /// If the parameters of methods should result in directed association.
    Flag!"genClassParamDependency" genClassParamDependency();

    /// If the inheritance hierarchy between classes is generated.
    Flag!"genClassInheritDependency" genClassInheritDependency();

    /// If the class members result in dependency on those members.
    Flag!"genClassMemberDependency" genClassMemberDependency();

    /** In all diagrams generate an "!include" of the style file.
     *
     * If the file PREFIX_style do not exist, create it with a minimal style.
     * Currently just the direction but may change in the future.
     */
    Flag!"doStyleIncl" doStyleIncl();
}

/// Data produced by the generator like files.
@safe interface Products {
    /** Data pushed from the generator to be written to files.
     *
     * The put value is the code generation tree. It allows the caller of
     * Generator to inject more data in the tree before writing. For example a
     * custom header.
     *
     * Params:
     *   fname = file the content is intended to be written to.
     *   data = data to write to the file.
     */
    void putFile(FileName fname, PlantumlRootModule data);

    /// ditto.
    void putFile(FileName fname, PlantumlModule data);
}

/** Relations to targets with count and kind.
 *
 * Intented to be used in a hashmap with the key as the "from".
 */
@safe struct Relate {
    alias Key = Typedef!(string, string.init, "RelateKey");

    enum Kind {
        None,
        Extend,
        Compose,
        Aggregate,
        Associate,
        Relate
    }

    private alias Inner = Tuple!(uint, "count", Kind, "kind");
    private Inner[][Key] to;

    void put(Key to_, Kind kind) {
        auto v = to_ in to;
        if (v is null) {
            to[to_] = Inner[].init;
            v = to_ in to;
        }

        // ugly algorithm, use an inner hashmap instead
        bool is_new = true;
        foreach (ref r; *v) {
            if (r.kind == kind) {
                r.count++;
                is_new = false;
                break;
            }
        }

        if (is_new) {
            *v ~= Inner(1, kind);
        }
    }

    /// Convert the TO/value store to a FROM-KIND-TO-COUNT array.
    auto toFlatArray(const Relate.Key from) pure const @trusted {
        import std.algorithm : filter, map, joiner;
        import std.array : array;

        alias RelateTuple = Tuple!(Relate.Key, "from", Kind, "kind",
                Relate.Key, "to", uint, "count");

        // dfmt off
        return to.byKeyValue.map!(a => a.value
                                    .filter!(b => b.kind != Kind.None)
                                    .map!(b => RelateTuple(from, b.kind, a.key, b.count))
                                    .array())
            .joiner()
            .array();
        // dfmt on
    }

    auto toStringArray(const Relate.Key from) pure const @trusted {
        import std.algorithm : map;
        import std.conv : text;
        import std.format : format;
        import std.array : array;

        // dfmt off
        return this.toFlatArray(from)
            .map!(b => format("%s -%s- [%d]%s", cast(string) b.from, text(b.kind), b.count, cast(string) b.to))
            .array();
        // dfmt on
    }
}

/** UML Class Diagram.
 *
 * Not designed for the general case.
 * The design is what the plantuml plugin needs when analyzing more than one
 * file. This is the container that is then passed between the analyze stages.
 *
 * All classes must exist in "classes".
 * It is common that during data gathering a CppClass is found to be related to
 * another class by a FullyQualifiedNameType so the relation is added before
 * the class represented by the FullyQualifiedNameType is added.
 *
 * A --> B
 * Directed relation.
 * A can have many connections to B.
 *
 * Store of R[A.B].
 * When analyzing the structural data it is this kind of relations that are
 * found. From a CppClass to many X, where X is other CppClass.
 * The key used must be unique, thus the choice of using fully qualified name.
 *
 * Example of relations.
 * A --> B (member)
 * A --> B (member)
 * A --> B (inherit)
 * B --> A (member)
 *
 * relate[A].put(B, Compose)
 * relate[A].put(B, Compose)
 * relate[A].put(B, Extend)
 * relate[B].put(A, Compose)
 *
 * The relations are of the kind Fan-out.
 */
@safe class UMLClassDiagram {
    alias Key = Typedef!(string, string.init, "UMLKey");

    struct Class {
        bool isInterface;
        string[] content;
    }

    /// The class is only added if it doesn't already exist in the store.
    void put(Key key) {
        if (key !in classes) {
            classes[key] = Class.init;
            relateTo[cast(Relate.Key) key] = Relate.init;
        }
    }

    void put(Key key, string content)
    in {
        assert(key in classes);
    }
    body {
        classes[key].content ~= content;
    }

    void put(Key key, Flag!"isInterface" isInterface)
    in {
        assert(key in classes);
    }
    body {
        classes[key].isInterface = isInterface;
    }

    /** Add a relation between two classes and increase the count on the class
     * related TO.
     */
    void relate(Key from, Key to, Relate.Kind kind)
    out {
        assert(from in classes);
        assert(to in classes);
        assert(kind != Relate.Kind.None);
    }
    body {
        put(to);
        relateTo[cast(Relate.Key) from].put(cast(Relate.Key) to, kind);
    }

    private string[] classesToStringArray() const pure @trusted {
        import std.algorithm : map, joiner;
        import std.array : array;
        import std.ascii : newline;
        import std.conv : text;
        import std.format : format;
        import std.range : only, chain, takeOne;

        // dfmt off
        return classes.byKeyValue.map!(a => chain(only(format("%s%s", a.key.str, a.value.content.length == 0 ? "" : " {")),
                                                  a.value.content.dup.map!(b => "  " ~ b),
                                                  a.value.content.takeOne.map!(b => "} // " ~ a.key.str))
                                       .joiner(newline)
                                       .text)
            .array();
        // dfmt on
    }

    private string[] relateToStringArray() const pure @trusted {
        import std.algorithm : map, joiner;
        import std.array;

        return relateTo.byKeyValue.map!(a => a.value.toStringArray(a.key)).joiner().array();
    }

    /// Return: Flat array of all relations of type FROM-KIND-TO-COUNT.
    auto relateToFlatArray() pure const @trusted {
        import std.algorithm : map, joiner;
        import std.array;

        return relateTo.byKeyValue.map!(a => a.value.toFlatArray(a.key)).joiner().array();
    }

    auto sortedClassRange() pure @trusted {
        import std.array : array;
        import std.algorithm;
        import std.typecons : tuple;
        import std.algorithm : makeIndex, uniq, map;

        //TODO how to do this without so much generated GC

        // dfmt off
        auto arr = classes.byKeyValue
            .map!(a => tuple(a.key, a.value))
            .array();
        auto index = new size_t[arr.length];

        makeIndex!((a, b) => a[0].str < b[0].str)(arr, index);

        return index.map!(i => arr[i]).array();
        // dfmt on
    }

    override string toString() @safe pure const {
        import std.ascii : newline;
        import std.algorithm : joiner;
        import std.conv : text;
        import std.format : format;
        import std.range : only, chain;

        // dfmt off
        return chain(only(format("UML Class Diagram (Total %d) {",classes.length)),
                     classesToStringArray,
                     relateToStringArray,
                     only("} // UML Class Diagram"),
                     ).joiner(newline).text;
        // dfmt on
    }

private:
    Class[Key] classes;
    Relate[Relate.Key] relateTo;
}

/** UML Component Diagram.
 *
 * Not designed for the general case.
 * The design is what the plantuml plugin needs when analyzing more than one
 * file. This is the container that is then passed between the analyze stages.
 *
 * The relations are of the kind Fan-out.
 */
@safe class UMLComponentDiagram {
    alias Key = Typedef!(string, string.init, "UMLKey");

    struct Component {
        string displayName;
        string[] toFile;
    }

    /// The component is only added if it doesn't already exist in the store.
    void put(Key key, string displayName) {
        if (key !in components) {
            components[key] = Component(displayName);
            relateTo[cast(Relate.Key) key] = Relate.init;
        }
    }

    /** Add a relation between two components and increase the count on the class
     * related TO.
     */
    void relate(Key from, Key to, string toDisplayName, Relate.Kind kind)
    out {
        assert(from in components);
        assert(to in components);
        assert(kind != Relate.Kind.None);
    }
    body {
        put(to, toDisplayName);
        relateTo[cast(Relate.Key) from].put(cast(Relate.Key) to, kind);

        components[from].toFile ~= cast(string) to;
    }

    /// Return: Flat array of all relations of type FROM-KIND-TO-COUNT.
    auto relateToFlatArray() pure const @trusted {
        import std.algorithm : map, joiner;
        import std.array : array;

        return relateTo.byKeyValue.map!(a => a.value.toFlatArray(a.key)).joiner().array();
    }

    auto sortedRange() const pure @trusted {
        import std.array : array;
        import std.algorithm : map, makeIndex;
        import std.typecons : tuple;
        import std.algorithm : makeIndex, map;

        // dfmt off
        auto arr = components.byKeyValue
            .map!(a => tuple(a.key, a.value))
            .array();
        auto index = new size_t[arr.length];

        makeIndex!((a, b) => a[1].displayName < b[1].displayName)(arr, index);

        return index.map!(i => arr[i]).array();
        // dfmt on
    }

    private string[] relateToStringArray() const pure @trusted {
        import std.algorithm : map, joiner;
        import std.array : array;

        return relateTo.byKeyValue.map!(a => a.value.toStringArray(a.key)).joiner().array();
    }

    private string[] componentsToStringArray() const pure @trusted {
        import std.algorithm : map;
        import std.array : array;
        import std.format : format;

        return sortedRange.map!(a => format("%s as %s", a[0].str, a[1].displayName)).array();
    }

    override string toString() @safe pure const {
        import std.ascii : newline;
        import std.algorithm : joiner;
        import std.conv : text;
        import std.format : format;
        import std.range : only, chain;

        // dfmt off
        return chain(only(format("UML Component Diagram (Total %d) {", components.length)),
                     componentsToStringArray,
                     relateToStringArray,
                     only("} // UML Component Diagram"),
                     ).joiner(newline).text;
        // dfmt on
    }

private:
    Component[Key] components;
    Relate[Relate.Key] relateTo;
}

@Name("Should be a None relate not shown and an extended relate")
unittest {
    Relate r;
    r.put(Relate.Key("B"), Relate.Kind.None);
    r.put(Relate.Key("B"), Relate.Kind.Extend);

    r.toStringArray(Relate.Key("A")).shouldEqual(["A -Extend- [1]B"]);
}

@Name("Should be all types of relates")
unittest {
    Relate r;
    r.put(Relate.Key("B"), Relate.Kind.None);
    r.put(Relate.Key("B"), Relate.Kind.Extend);
    r.put(Relate.Key("B"), Relate.Kind.Compose);
    r.put(Relate.Key("B"), Relate.Kind.Aggregate);
    r.put(Relate.Key("B"), Relate.Kind.Associate);

    r.toStringArray(Relate.Key("A")).shouldEqual(["A -Extend- [1]B",
            "A -Compose- [1]B", "A -Aggregate- [1]B", "A -Associate- [1]B"]);
}

@Name("Should be two relates to the same target")
unittest {
    Relate r;
    r.put(Relate.Key("B"), Relate.Kind.Compose);
    r.put(Relate.Key("B"), Relate.Kind.Compose);

    r.toStringArray(Relate.Key("A")).shouldEqual(["A -Compose- [2]B"]);
}

@Name("Should be a UML diagram with one class")
unittest {
    import unit_threaded : writelnUt;

    auto uml = new UMLClassDiagram;
    uml.put(UMLClassDiagram.Key("A"));

    writelnUt(uml.toString);
    uml.toString.shouldEqualPretty("UML Class Diagram (Total 1) {
A
} // UML Class Diagram");
}

@Name("Should add a CppClass to the UML diagram, with methods")
unittest {
    import cpptooling.data.representation;

    auto uml = new UMLClassDiagram;
    auto c = CppClass(CppClassName("A"));
    {
        auto m = CppMethod(CppMethodName("fun"), CxReturnType(TypeKind.make("int")),
                CppAccess(AccessType.Public), CppConstMethod(false),
                CppVirtualMethod(VirtualType.Yes));
        c.put(m);
    }

    put(uml, c, Yes.genClassMethod, Yes.genClassParamDependency,
            Yes.genClassInheritDependency, Yes.genClassMemberDependency);

    uml.toString.shouldEqualPretty("UML Class Diagram (Total 1) {
A {
  +virtual int fun()
} // A
} // UML Class Diagram");
}

@Name("Should be a UML diagram with two classes related")
unittest {
    auto uml = new UMLClassDiagram;
    auto ka = UMLClassDiagram.Key("A");
    auto kb = UMLClassDiagram.Key("B");
    uml.put(ka);
    uml.put(kb);

    uml.relate(ka, kb, Relate.Kind.Extend);

    uml.toString.shouldEqualPretty("UML Class Diagram (Total 2) {
A
B
A -Extend- [1]B
} // UML Class Diagram");
}

@Name("Should be a UML Component diagram with two components related")
unittest {
    import unit_threaded;

    auto uml = new UMLComponentDiagram;
    auto ka = UMLComponentDiagram.Key("a");
    auto kb = UMLComponentDiagram.Key("b");
    uml.put(ka, "A");

    uml.relate(ka, kb, "B", Relate.Kind.Relate);

    writelnUt(uml.toString);
    uml.toString.shouldEqualPretty("UML Component Diagram (Total 2) {
a as A
b as B
a -Relate- [1]b
} // UML Component Diagram");
}

struct Generator {
    import cpptooling.data.representation : CppRoot;
    import cpptooling.data.symbol.container : Container;

    static struct Modules {
        PlantumlModule classes;
        PlantumlModule components;

        static auto make() {
            Modules m;

            //TODO how to do this with meta-programming and introspection of Modules?
            m.classes = new PlantumlModule;
            //TODO activate suppression. NOT done in this PR. Results in too
            // much noise.
            //m.classes.suppressIndent(1);
            m.components = new PlantumlModule;
            m.components.suppressIndent(1);

            return m;
        }
    }

    this(Controller ctrl, Parameters params, Products products) {
        this.ctrl = ctrl;
        this.params = params;
        this.products = products;
        this.uml_class = new UMLClassDiagram;
        this.uml_component = new UMLComponentDiagram;
    }

    void analyze(ref CppRoot root, ref Container container) {
        import std.ascii;
        import cpptooling.data.representation : CppNamespace, CppNs;

        logger.trace("Raw:\n", root.toString());

        auto fl = rawFilter(root, ctrl, products);
        logger.trace("Filtered:\n", fl.toString());

        translate(fl, uml_class, params);
        translate(fl, uml_component, ctrl, params, container);
        logger.trace("Translated:\n", uml_class.toString, newline, uml_component.toString);
    }

    auto process() {
        auto m = Modules.make();
        generate(uml_class, uml_component, m);
        postProcess(ctrl, params, products, m);
    }

private:
    Controller ctrl;
    Parameters params;
    Products products;
    UMLClassDiagram uml_class;
    UMLComponentDiagram uml_component;

    static void postProcess(Controller ctrl, Parameters params, Products prods, Modules m) {
        static PlantumlRootModule makeMinimalStyle(Flag!"genClassMethod" show_methods) {
            auto proot = PlantumlRootModule.make();

            auto m = new PlantumlModule;
            m.stmt("left to right direction");
            m.stmt("skinparam componentStyle uml2");
            m.stmt("set namespaceSeparator ::");
            if (!show_methods) {
                m.stmt("hide members");
            }
            proot.content.append(m);

            return proot;
        }

        static PlantumlModule makeStyleInclude(FileName style_file) {
            auto m = new PlantumlModule;
            m.stmt("!include " ~ cast(string) style_file);

            return m;
        }

        static void make(Products prods, FileName fname, PlantumlModule style,
                PlantumlModule content) {
            import std.algorithm : filter;

            auto proot = PlantumlRootModule.make();

            foreach (m; [style, content].filter!(a => a !is null)) {
                proot.content.append(m);
            }

            prods.putFile(fname, proot);
        }

        PlantumlModule style;

        if (params.doStyleIncl) {
            style = makeStyleInclude(params.getFiles.styleIncl);
        }

        if (ctrl.genStyleInclFile) {
            prods.putFile(params.getFiles.styleOutput, makeMinimalStyle(params.genClassMethod));
        }

        make(prods, params.getFiles.classes, style, m.classes);
        make(prods, params.getFiles.components, style, m.components);
    }
}

private:
@safe:

import cpptooling.data.representation : CppRoot, CppClass, CppMethod, CppCtor,
    CppDtor, CppNamespace, CxLocation;
import cpptooling.data.symbol.container : Container;
import cpptooling.utility.conv : str;
import dsrcgen.plantuml;

/** Structurally filter the data to remove unwanted parts.
 *
 * Remove:
 *  - free functions.
 *  - global variables.
 *  - anonymouse namespaces.
 *
 * Params:
 *  ctrl: control what symbols are kept, thus processed further
 */
CppRoot rawFilter(CppRoot input, Controller ctrl, Products prod) {
    import std.algorithm : each, filter, map;
    import cpptooling.data.representation : VirtualType;

    auto raw = CppRoot(input.location);

    // dfmt off
    input.namespaceRange
        .filter!(a => !a.isAnonymous)
        .map!(a => rawFilter(a, ctrl, prod))
        .each!(a => raw.put(a));

    input.classRange
        // ask controller if the file should be processed
        .filter!(a => ctrl.doFile(a.location.file, cast(string) a.name ~ " " ~ a.location.toString))
        .each!(a => raw.put(a));
    // dfmt on

    return raw;
}

/// ditto
CppNamespace rawFilter(CppNamespace input, Controller ctrl, Products prod)
in {
    assert(!input.isAnonymous);
    assert(input.name.length > 0);
}
body {
    import std.algorithm : each, filter, map;

    auto ns = CppNamespace.make(input.name);

    // dfmt off
    input.namespaceRange
        .filter!(a => !a.isAnonymous)
        .map!(a => rawFilter(a, ctrl, prod))
        .each!(a => ns.put(a));

    input.classRange
        // ask controller if the file should be processed
        .filter!(a => ctrl.doFile(a.location.file, cast(string) a.name ~ " " ~ a.location.toString))
        .each!(a => ns.put(a));
    //dfmt on

    return ns;
}

bool isPrimitiveType(FullyQualifiedNameType type) {
    import std.algorithm : among;

    //TODO really ugly, consider some other way of doing this.
    // Copied from translateCursorType.
    // This is hard to keep in sync and error prone.

    return 0 != type.among("void", "bool", "unsigned char", "unsigned short", "unsigned int", "unsigned long",
            "unsigned long long", "char", "wchar", "short", "int", "long",
            "long long", "float", "double", "long double", "null");
}

void put(UMLClassDiagram uml, CppClass c, Flag!"genClassMethod" class_method,
        Flag!"genClassParamDependency" class_param_dep,
        Flag!"genClassInheritDependency" class_inherit_dep,
        Flag!"genClassMemberDependency" class_member_dep) {
    import std.algorithm : each, map, filter, joiner;
    import std.array : array;
    import cpptooling.data.representation;

    static string getMethod(T)(T method_, string prefix) @trusted {
        import std.variant : visit;

        return method_.visit!((CppMethod m) => prefix ~ m.toString,
                (CppMethodOp m) => prefix ~ m.toString,
                (CppCtor m) => prefix ~ m.toString, (CppDtor m) => prefix ~ m.toString);
    }

    static auto getMemberRelation(TypeKindVariable tkv) {
        import std.typecons : tuple;

        //TODO investigate why strip is needed when analyzing gtest
        import std.string : strip;

        final switch (tkv.type.info.kind) with (TypeKind.Info) {
        case Kind.record:
            return tuple(Relate.Key(tkv.type.info.type.strip), Relate.Kind.Aggregate);
        case Kind.simple:
            if (tkv.type.isRecord && (tkv.type.isPtr || tkv.type.isRef)) {
                return tuple(Relate.Key(tkv.type.info.type.strip), Relate.Kind.Compose);
            }
            return tuple(Relate.Key(""), Relate.Kind.None);
        case TypeKind.Info.Kind.func:
            goto case;
        case Kind.array:
            goto case;
        case Kind.funcPtr:
            goto case;
        case Kind.null_:
            return tuple(Relate.Key(""), Relate.Kind.None);
        }
    }

    static auto getMethodRelation(ref CppClass.CppFunc f) {
        import std.array : array;
        import std.algorithm : among, map;
        import std.variant : visit;
        import std.range : chain, only;
        import std.typecons : TypedefType, Tuple;

        alias Rtuple = Tuple!(Relate.Kind, "kind", Relate.Key, "key");

        static Rtuple getTypeRelation(TypeKind tk) {
            //TODO investigate why strip is needed when analyzing gtest
            import std.string : strip;

            auto r = Rtuple(Relate.Kind.None, Relate.Key(""));

            final switch (tk.info.kind) with (TypeKind.Info) {
            case Kind.record:
                r[0] = Relate.Kind.Associate;
                r[1] = tk.info.type.strip;
                break;
            case Kind.simple:
                if (tk.isRecord && (tk.isPtr || tk.isRef)) {
                    r[0] = Relate.Kind.Associate;
                    r[1] = tk.info.type.strip;
                }
                break;
            case TypeKind.Info.Kind.func:
                break;
            case Kind.array:
                r[0] = Relate.Kind.Associate;
                r[1] = tk.info.elementType.strip;
                break;
            case Kind.funcPtr:
                break;
            case Kind.null_:
                break;
            }

            if ((cast(FullyQualifiedNameType) r.key).isPrimitiveType) {
                r[0] = Relate.Kind.None;
            }

            return r;
        }

        static Rtuple genParam(CxParam p) @trusted {
            return p.visit!((TypeKindVariable tkv) => getTypeRelation(tkv.type),
                    (TypeKind tk) => getTypeRelation(tk), (VariadicType vk) {
                        logger.error(
                            "Variadic function not supported. Would require runtime information to relate.");
                        return Rtuple.init;
                    });
        }

        static Rtuple[] genMethod(T)(T f) {
            return chain(f.paramRange.map!(a => genParam(a)),
                    only(getTypeRelation(cast(TypedefType!CxReturnType) f.returnType))).array();
        }

        static Rtuple[] genCtor(CppCtor f) {
            return f.paramRange.map!(a => genParam(a)).array();
        }

        static Rtuple[] internalVisit(ref CppClass.CppFunc f) @trusted {
            return f.visit!((CppMethod m) => genMethod(m),
                    (CppMethodOp m) => genMethod(m), (CppCtor m) => genCtor(m),
                    (CppDtor m) => [Rtuple.init]);
        }

        return internalVisit(f);
    }

    auto key = UMLClassDiagram.Key(cast(string) c.fullyQualifiedName);

    uml.put(key);
    uml.put(key, cast(Flag!"isInterface") c.isPureInterface);

    // dfmt off
    if (class_method) {
        c.methodPublicRange.map!(a => getMethod(a, "+")).each!(a => uml.put(key, a));
    }

    if (class_inherit_dep) {
        c.inheritRange
            .map!(a => Relate.Key(a.fullyQualifiedName.str))
            .each!(a => uml.relate(key, cast(UMLClassDiagram.Key) a, Relate.Kind.Extend));
    }

    if (class_member_dep) {
        c.memberRange
            .map!(a => getMemberRelation(a))
            .filter!(a => a[1] != Relate.Kind.None)
            .each!(a => uml.relate(key, cast(UMLClassDiagram.Key) a[0], a[1]));
    }

    if (class_param_dep) {
        foreach (a; c.methodRange
                 .map!(a => getMethodRelation(a))
                 // flatten the range
                 .joiner()
                 .filter!(a => a.kind != Relate.Kind.None)
                 // remove self referencing keys, would result in circles which
                 // just clutters the diagrams
                 .filter!(a => a.key != key)) {
            uml.relate(key, cast(UMLClassDiagram.Key) a.key, a.kind);
        }
    }
    // dfmt on
}

void put(UMLComponentDiagram uml, CppClass c, Controller ctrl, ref Container container) {
    import std.algorithm : map, filter, cache, joiner;
    import std.range : only, chain, array, dropOne;
    import cpptooling.data.representation;
    import cpptooling.data.symbol.types;

    alias KeyValue = Tuple!(UMLComponentDiagram.Key, "key", string, "display",
            string, "absFilePath");
    alias KeyRelate = Tuple!(string, "file", KeyValue, "key", Relate.Kind, "kind");
    alias PathKind = Tuple!(string, "file", Relate.Kind, "kind");

    /** Calculate the key based on the directory the file that declares the symbol exist in.
     *
     * Additional metadata as to make it possible to backtrack.
     */
    static KeyValue makeKey(in string location_file, Controller ctrl) @trusted {
        import std.base64;
        import std.path;
        import std.array : appender;
        import std.typecons : tuple;

        //TODO consider using a hash function to shorten the length of the encoded path

        alias SafeBase64 = Base64Impl!('-', '_', Base64.NoPadding);

        string file_path = buildNormalizedPath(location_file).absolutePath;
        string strip_path = cast(string) ctrl.doComponentNameStrip(FileName(file_path.dirName));
        string rel_path = relativePath(strip_path);
        string display_name = strip_path.baseName;

        auto enc = appender!(char[])();
        SafeBase64.encode(cast(ubyte[]) rel_path, enc);

        auto k = KeyValue(UMLComponentDiagram.Key(enc.data.idup), display_name, strip_path);

        debug {
            logger.tracef("Component:%s stripped:%s file:%s base64:%s",
                    k.display, strip_path, file_path, cast(string) k.key);
        }

        return k;
    }

    static auto lookupType(TypeKind tk, ref Container container) {
        //TODO investigate why strip is needed when analyzing gtest
        import std.string : strip;

        auto type_lookup = only(FullyQualifiedNameType(string.init)).dropOne;
        auto rval = only(PathKind()).dropOne;

        final switch (tk.info.kind) with (TypeKind.Info) {
        case Kind.record:
            type_lookup = only(FullyQualifiedNameType(tk.info.type.strip));
            break;
        case Kind.simple:
            if (tk.isRecord && (tk.isPtr || tk.isRef)) {
                type_lookup = only(FullyQualifiedNameType(tk.info.type.strip));
            }
            break;
        case TypeKind.Info.Kind.func:
            break;
        case Kind.array:
            type_lookup = only(FullyQualifiedNameType(tk.info.elementType.strip));
            break;
        case Kind.funcPtr:
            break;
        case Kind.null_:
            break;
        }

        // dfmt off
        foreach (c; type_lookup
                 .filter!(a => !a.isPrimitiveType)
                 .map!(a => container.find!CppClass(a)).joiner()
                 ) {
            rval = only(PathKind(c.location.file, Relate.Kind.None));
        }
        // dfmt on

        return rval;
    }

    static auto getMemberRelation(TypeKindVariable tkv, ref Container container) {
        import std.typecons : tuple;

        return lookupType(tkv.type, container).map!(a => PathKind(a.file, Relate.Kind.Associate));
    }

    static auto getInheritRelation(CppInherit inherit, ref Container container) {
        auto rval = only(PathKind()).dropOne;

        foreach (c; container.find!CppClass(inherit.fullyQualifiedName)) {
            rval = only(PathKind(c.location.file, Relate.Kind.Associate));
        }

        return rval;
    }

    static PathKind[] getMethodRelation(ref CppClass.CppFunc f, ref Container container) {
        static auto genParam(CxParam p, ref Container container) @trusted {
            import std.variant : visit;

            // dfmt off
            return p.visit!(
                    (TypeKindVariable tkv) => lookupType(tkv.type, container),
                    (TypeKind tk) => lookupType(tk, container),
                    (VariadicType vk) {
                        logger.error(
                            "Variadic function not supported. Would require runtime information to relate.");
                        return only(PathKind()).dropOne;
                    });
            // dfmt on
        }

        static auto genMethod(T)(T f, ref Container container) {
            import std.typecons : TypedefType;

            // dfmt off
            return chain(f.paramRange.map!(a => genParam(a, container)).joiner(),
                         lookupType(cast(TypedefType!CxReturnType) f.returnType, container));
            // dfmt on
        }

        static auto genCtor(CppCtor f, ref Container container) {
            return f.paramRange.map!(a => genParam(a, container)).joiner();
        }

        static PathKind[] internalVisit(ref CppClass.CppFunc f, ref Container container) @trusted {
            import std.variant : visit;

            // dfmt off
            return f.visit!((CppMethod m) => genMethod(m, container).array(),
                    (CppMethodOp m) => genMethod(m, container).array(),
                    (CppCtor m) => genCtor(m, container).array(),
                    (CppDtor m) => PathKind[].init);
            // dfmt on
        }

        auto rval = PathKind[].init;

        return internalVisit(f, container).map!(a => PathKind(a.file,
                Relate.Kind.Associate)).array();
    }

    auto key = makeKey(c.location.file, ctrl);
    uml.put(key.key, key.display);

    // dfmt off
    foreach (a; chain(c.memberRange.map!(a => getMemberRelation(a, container)).joiner(),
                      c.inheritRange.map!(a => getInheritRelation(a, container)).joiner(),
                      c.methodRange.map!(a => getMethodRelation(a, container)).joiner()
                      )
        // ask controller if the file should be processed
        .filter!(a => ctrl.doFile(a.file, cast(string) a.file))
        .map!(a => KeyRelate(a.file, makeKey(a.file, ctrl), a.kind))
        .cache
        // self referencing components are invalid
        .filter!(a => a.key != key)) {
        uml.relate(key.key, a.key.key, a.key.display, a.kind);
    }
    // dfmt on
}

void translate(CppRoot input, UMLClassDiagram uml_class, Parameters params) {
    foreach (ref c; input.classRange) {
        put(uml_class, c, params.genClassMethod, params.genClassParamDependency,
                params.genClassInheritDependency, params.genClassMemberDependency);
    }

    foreach (ref ns; input.namespaceRange) {
        translateNs(ns, uml_class, params);
    }
}

void translateNs(CppNamespace input, UMLClassDiagram uml_class, Parameters params) {
    foreach (ref c; input.classRange) {
        put(uml_class, c, params.genClassMethod, params.genClassParamDependency,
                params.genClassInheritDependency, params.genClassMemberDependency);
    }

    foreach (ref ns; input.namespaceRange) {
        translateNs(ns, uml_class, params);
    }
}

void translate(CppRoot input, UMLComponentDiagram uml_comp, Controller ctrl,
        Parameters params, ref Container container) {
    foreach (ref c; input.classRange) {
        put(uml_comp, c, ctrl, container);
    }

    foreach (ref ns; input.namespaceRange) {
        translateNs(ns, uml_comp, ctrl, params, container);
    }
}

void translateNs(CppNamespace input, UMLComponentDiagram uml_comp,
        Controller ctrl, Parameters params, ref Container container) {
    foreach (ref c; input.classRange) {
        put(uml_comp, c, ctrl, container);
    }

    foreach (ref ns; input.namespaceRange) {
        translateNs(ns, uml_comp, ctrl, params, container);
    }
}

void generate(UMLClassDiagram uml_class, UMLComponentDiagram uml_comp, Generator.Modules modules) {
    import std.algorithm : each;

    foreach (kv; uml_class.sortedClassRange) {
        generate(kv[0], kv[1], modules.classes);
    }
    generateClassRelate(uml_class.relateToFlatArray, modules.classes);

    foreach (kv; uml_comp.sortedRange) {
        generate(kv[0], kv[1], modules.components);
    }
    generateComponentRelate(uml_comp.relateToFlatArray, modules.components);
}

void generate(UMLClassDiagram.Key name, UMLClassDiagram.Class c, PlantumlModule m) {
    import std.algorithm : each;

    ClassType pc;

    if (c.content.length == 0) {
        pc = m.class_(cast(string) name);
    } else {
        pc = m.classBody(cast(string) name);
        c.content.each!(a => pc.method(a));
    }

    if (c.isInterface) {
        //TODO add a plantuml macro and use that as color for interface
        // Allows the user to control the color via the PREFIX_style.iuml
        import dsrcgen.plantuml;

        pc.addSpot.text("(I, LightBlue)");
    }
}

void generateClassRelate(T)(T relate_range, PlantumlModule m) {
    static auto convKind(Relate.Kind kind) {
        static import dsrcgen.plantuml;

        final switch (kind) with (Relate.Kind) {
        case None:
            assert(0);
        case Extend:
            return dsrcgen.plantuml.Relate.Extend;
        case Compose:
            return dsrcgen.plantuml.Relate.Compose;
        case Aggregate:
            return dsrcgen.plantuml.Relate.Aggregate;
        case Associate:
            return dsrcgen.plantuml.Relate.ArrowTo;
        case Relate:
            return dsrcgen.plantuml.Relate.Relate;
        }
    }

    foreach (r; relate_range) {
        m.relate(cast(ClassNameType) r.from, cast(ClassNameType) r.to, convKind(r.kind));
    }
}

void generate(UMLComponentDiagram.Key key,
        const UMLComponentDiagram.Component component, PlantumlModule m) {
    auto comp = m.component(component.displayName);
    comp.addAs.text(cast(string) key);
}

void generateComponentRelate(T)(T relate_range, PlantumlModule m) {
    static auto convKind(Relate.Kind kind) {
        static import dsrcgen.plantuml;

        final switch (kind) with (Relate.Kind) {
        case Relate:
            return dsrcgen.plantuml.Relate.Relate;
        case Extend:
            assert(0);
        case Compose:
            assert(0);
        case Aggregate:
            assert(0);
        case Associate:
            return dsrcgen.plantuml.Relate.ArrowTo;
        case None:
            assert(0);
        }
    }

    foreach (r; relate_range) {
        m.relate(cast(ComponentNameType) r.from, cast(ComponentNameType) r.to, convKind(r.kind));
    }
}