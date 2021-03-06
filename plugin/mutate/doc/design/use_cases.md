# REQ-plugin_mutate-use_case
This is a meta requirement for those that are traceable to use cases.

An important aspect is ease of use in day-to-day development. When verification is performed late in the development process, one discovers generally a huge amount of problems, and fixing them requires a tremendous effort; it is sometimes extremely difficult to do when the software has already gone through various validation phases that would be ruined by massive corrections.

When the tool is integrated into the development environment programmers must be able to run it routinely each time they develop new modules or modify existing ones. Ideally as part of the code compile step. The sooner checking is performed in the development process, the better.

# REQ-plugin_mutate_early_validation
partof: REQ-plugin_mutate-use_case
###
This plugin should be easy to use in the day-to-day development.

The plugin should be _fast_ when the changes in the code base are *small*.

The plugin should be _fast_ when performing whole program mutation.
**NOTE**: will require scaling over a computer cluster.

The plugin should produce a detailed report for the user to understand what mutations have been done and where.

The plugin should on request visualize the changes to the code.
**NOTE**: produce the mutated source code.

The plugin should be easy to integrate with an IDE for visual feedback to the user.

# REQ-plugin_mutate_inspection_of_test_proc
partof: REQ-plugin_mutate-use_case
###
This plugin should replace or simplify parts of the inspection as required by DO-178C.

The type of mutations to implemented should be derived and traced to the following statement and list.

The inspection should verify that the test procedures have used the required test design methods in DO-178C:
 * Boundary value analysis,
 * Equivalence class partitioning,
 * State machine transition,
 * Variable and Boolean operator usage,
 * Time-related functions test,
 * Robustness range test design for techniques above

See [@softwareVerAndVal] for inspiration

## Note
It is costly to develop test cases because inspection is used to verify that they adher to the test design methods by manual inspection. The intention is to try and automate parts or all of this to lower the development cost and at the same time follow DO-178C.

# REQ-plugin_mutate_test_design_metric
partof: REQ-plugin_mutate_inspection_of_test_proc
###
The plugin should produce metrics for how well the design methods in [[REQ-plugin_mutate_inspection_of_test_proc]] has been carried out.

Regarding code coverage:
 * The modified condition / decision coverage shows to some extent that boolean operators have been exercised. However, it does not require the observed output to be verified by a testing oracle.

Regarding mutation:
 * By injecting faults in the source code and executing the test suite on all mutated versions of the program, the quality of the requirements based test can be measured in mutation score. Ideally the mutation operations should be representative of all realistic type of faults that could occur in practice.

# SPC-plugin_mutate_incremental_mutation
partof: REQ-plugin_mutate_early_validation
###
The plugin shall support incremental mutation.

A change of one statement should only generate mutants for that change.

A change to a file should only generate mutants derived from that file.

## Notes
The user will spend time on performing a manual analysis of the mutants.

To make it easier for the user it is important that this manual analysis can be reused as much as possible when the SUT changes.

A draft of a workflow and architecture would be.
 * The user has a report of live mutants.
 * The user goes through the live mutants and mark some as equivalent mutations.
 * The result is saved in a file X.
 * Time goes by and the SUT changes in a couple of files.
 * The user rerun the analyzer.
     The analyzer repopulates the internal database with new mutations for the changed files.
 * The user run the mutant tester. The mutant tester only test those mutations that are in the changed files.
 * The user import the previous analysis from file X into deXtool.
 * The user export a mutation result report to file Y (same fileformat as X).
 * The user only has to go through and determine equivalence for the new mutations.
