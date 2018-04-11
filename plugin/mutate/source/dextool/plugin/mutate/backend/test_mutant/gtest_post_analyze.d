/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

#SPC-plugin_mutate_track_gtest
*/
module dextool.plugin.mutate.backend.test_mutant.gtest_post_analyze;

import std.exception : collectException;
import std.range : isInputRange, isOutputRange;
import logger = std.experimental.logger;

import dextool.type : AbsolutePath;
import dextool.plugin.mutate.backend.type : TestCase;

/** Parse input for google test cases.
Params:
    r = range that is chunked by line
  */
void process(T, T1)(T r, ref T1 sink, AbsolutePath reldir) if (isInputRange!T) {
    import std.algorithm : until;
    import std.format : format;
    import std.range : put;
    import std.regex : regex, ctRegex, matchFirst;
    import std.string : strip;
    import std.path : isValidPath, relativePath;

    enum re_run_block = ctRegex!(`^\[\s*RUN\s*\]`);
    enum re_fail_msg = ctRegex!(`^(?P<file>.*?):.*Failure`);
    enum re_failed_block = ctRegex!(`^\[\s*FAILED\s*\]\s*(?P<tc>.*)`);

    Data data;
    Action act;
    State st;

    string fail_msg_file;

    foreach (line; r) {
        auto fail_msg_match = matchFirst(line, re_fail_msg);
        auto failed_block_match = matchFirst(line, re_failed_block);
        data.hasRunBlock = !matchFirst(line, re_run_block).empty;
        data.hasFailedMessage = !fail_msg_match.empty;
        data.hasFailedBlock = !failed_block_match.empty;

        st = nextState(st, data, act);

        final switch (act) with (Action) {
        case none:
            break;
        case saveFileName:
            fail_msg_file = fail_msg_match["file"].strip;
            try {
                if (fail_msg_file.isValidPath)
                    fail_msg_file = relativePath(fail_msg_file, reldir);
            }
            catch (Exception e) {
                debug logger.trace(e.msg).collectException;
            }
            break;
        case putTestCase:
            put(sink, TestCase(format("%s:%s", fail_msg_file,
                    failed_block_match["tc"].until(' '))));
            break;
        case countLinesAfterRun:
            data.linesAfterRun += 1;
            break;
        case resetCounter:
            data.linesAfterRun = 0;
            break;
        }
    }
}

version (unittest) {
} else {
private:
}

enum State {
    findRun,
    findFailureMsg,
    findEndFailed,
}

enum Action {
    none,
    saveFileName,
    putTestCase,
    resetCounter,
    countLinesAfterRun,
}

struct Data {
    /// The line contains a [ RUN   ] block.
    bool hasRunBlock;
    /// The line contains a <path>:line: Failure.
    bool hasFailedMessage;
    /// the line contains a [ FAILED  ] block.
    bool hasFailedBlock;
    /// the line contains a [ OK   ] block.
    bool hasOkBlock;

    /// Number of lines since a [ RUN   ] block where encountered.
    uint linesAfterRun;
}

State nextState(const State current, const Data d, ref Action act) {
    State next = current;

    final switch (current) with (State) {
    case findRun:
        act = Action.resetCounter;
        if (d.hasRunBlock) {
            next = findFailureMsg;
        }
        break;
    case findFailureMsg:
        act = Action.countLinesAfterRun;

        if (d.hasFailedMessage) {
            next = findEndFailed;
            act = Action.saveFileName;
        } else if (d.linesAfterRun > 10) {
            // 10 is chosen to be somewhat resilient against junk in the output but still be conservative.
            next = findRun;
        } else if (d.hasOkBlock)
            next = findRun;
        else if (d.hasFailedBlock)
            next = findRun;
        break;
    case findEndFailed:
        act = Action.none;

        if (d.hasRunBlock)
            next = findFailureMsg;
        else if (d.hasFailedBlock) {
            act = Action.putTestCase;
            next = findRun;
        }
        break;
    }

    return next;
}

@("shall report the failed test case")
unittest {
    import std.array : appender;
    import std.file : getcwd;
    import dextool.type : FileName;
    import unit_threaded : shouldEqual;

    auto app = appender!(TestCase[])();
    auto reldir = AbsolutePath(FileName(getcwd));

    process(testData1, app, reldir);

    shouldEqual(app.data,
            ["./googletest/test/gtest-message_test.cc:MessageTest.DefaultConstructor"]);
}

version (unittest) {
    // dfmt off
    string[] testData1() {
        return [
"Running main() from gtest_main.cc",
"[==========] Running 17 tests from 1 test case.",
"[----------] Global test environment set-up.",
"[----------] 17 tests from MessageTest",
"[ RUN      ] MessageTest.DefaultConstructor",
"./googletest/test/gtest-message_test.cc:48: Failure",
"Expected equality of these values:",
"  true",
"  false",
"[  FAILED  ] MessageTest.DefaultConstructor (0 ms)",
"[ RUN      ] MessageTest.CopyConstructor",
"[       OK ] MessageTest.CopyConstructor (0 ms)",
"[ RUN      ] MessageTest.ConstructsFromCString",
"[       OK ] MessageTest.ConstructsFromCString (0 ms)",
"[----------] 3 tests from MessageTest (0 ms total)",
"",
"[----------] Global test environment tear-down",
"[==========] 3 tests from 1 test case ran. (0 ms total)",
"[  PASSED  ] 2 tests.",
"[  FAILED  ] 1 test, listed below:",
"[  FAILED  ] MessageTest.DefaultConstructor",
"",
" 1 FAILED TEST",
        ];
    // dfmt on
}
}
