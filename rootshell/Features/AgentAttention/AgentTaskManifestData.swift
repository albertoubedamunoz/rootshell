//
//  AgentTaskManifestData.swift
//  rootshell
//
//  Embedded task-detection manifest (kind: "task" entries), the second
//  hand-maintained payload merged into AgentDetectionManifest at load. A
//  Documents file named `TaskDetectionRules.json` overrides this side
//  for field debugging; older app versions never read that file, which
//  is why task entries live here and not in AgentDetectionRules.json.
//
//  Authoring contract (enforced at compile):
//  - every entry declares kind "task" and a family (prompts / tests /
//    builds / infra / transfers) — the family is its settings toggle
//  - rules may only address bottom-anchored regions
//  - working/blocked rules identify; done/failed rules only ever run
//    while the task is held
//  - working rules carry `not` gates excluding the tool's own summary
//    lines, so a finished run's residual screen text cannot re-adopt
//    and re-announce a completion
//  - done/failed only from machine-stable summary shapes (the lines CI
//    systems scrape); no freeform log interpretation
//

nonisolated enum AgentTaskManifestData {
    static let json: String = #"""
{
  "version": 1,
  "agents": [
    {
      "id": "prompt",
      "kind": "task",
      "family": "prompts",
      "displayName": "Terminal",
      "rules": [
        {
          "id": "sudo_password",
          "state": "blocked",
          "priority": 100,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["password"],
          "lineRegex": ["(?i)^(\\[sudo\\] )?password( for [^:]{1,64})?:\\s*$"]
        },
        {
          "id": "ssh_hostkey",
          "state": "blocked",
          "priority": 100,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["continue connecting"],
          "lineRegex": ["(?i)^are you sure you want to continue connecting \\(yes/no(/\\[fingerprint\\])?\\)\\?\\s*$"]
        },
        {
          "id": "ssh_passphrase",
          "state": "blocked",
          "priority": 95,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["passphrase"],
          "lineRegex": ["(?i)^enter passphrase for (key )?'?[^:]+:\\s*$"]
        },
        {
          "id": "git_credential",
          "state": "blocked",
          "priority": 95,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["for '"],
          "lineRegex": ["(?i)^(username|password) for '[^']+':\\s*$"]
        },
        {
          "id": "apt_confirm",
          "state": "blocked",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["do you want to continue"],
          "lineRegex": ["(?i)^do you want to continue\\? \\[y/n\\]\\s*$"]
        },
        {
          "id": "generic_yn",
          "state": "blocked",
          "priority": 10,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "any": [
            { "contains": ["y/n"] },
            { "contains": ["yes/no"] }
          ],
          "lineRegex": ["(?i)\\S.*[\\[(](y/n|yes/no|y/n/a)[\\])][?:]?\\s*$"]
        }
      ]
    },
    {
      "id": "pytest",
      "kind": "task",
      "family": "tests",
      "displayName": "pytest",
      "progress": { "regex": "\\[\\s*(\\d+)%\\]", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "summary_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["failed", " in "],
          "lineRegex": ["^=+ .*\\d+ (failed|error)[s,]?.* in \\d+(\\.\\d+)?s.* =+$"]
        },
        {
          "id": "summary_passed",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["passed", " in "],
          "lineRegex": ["^=+ \\d+ passed[^=]* in \\d+(\\.\\d+)?s.* =+$"]
        },
        {
          "id": "streaming",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["%]"],
          "lineRegex": ["^\\S+\\.py(::\\S+)?\\s+.*\\[\\s*\\d+%\\]\\s*$"],
          "not": [ { "lineRegex": ["^=+ .* in \\d+(\\.\\d+)?s.* =+$"] } ]
        },
        {
          "id": "session_start",
          "state": "working",
          "priority": 80,
          "region": "bottom_non_empty_lines(6)",
          "visibleWorking": true,
          "contains": ["test session starts"],
          "lineRegex": ["^=+ test session starts =+$"],
          "not": [ { "lineRegex": ["^=+ .* in \\d+(\\.\\d+)?s.* =+$"] } ]
        }
      ]
    },
    {
      "id": "jest",
      "kind": "task",
      "family": "tests",
      "displayName": "Jest",
      "rules": [
        {
          "id": "summary_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["tests:", "failed"],
          "lineRegex": ["^Tests:\\s+.*\\d+ failed.*\\d+ total$"]
        },
        {
          "id": "summary_passed",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["tests:", "total"],
          "lineRegex": ["^Tests:\\s+.*\\d+ total$"]
        },
        {
          "id": "running",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["runs "],
          "lineRegex": ["^\\s*RUNS\\s+\\S+"],
          "not": [ { "contains": ["tests:"] } ]
        },
        {
          "id": "streaming",
          "state": "working",
          "priority": 85,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "any": [
            { "contains": ["pass "] },
            { "contains": ["fail "] }
          ],
          "lineRegex": ["^\\s*(PASS|FAIL)\\s+\\S+\\.(test|spec)\\.\\S+"],
          "not": [ { "contains": ["tests:"] } ]
        }
      ]
    },
    {
      "id": "gotest",
      "kind": "task",
      "family": "tests",
      "displayName": "go test",
      "rules": [
        {
          "id": "summary_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["fail"],
          "lineRegex": ["^FAIL(\\s+\\S+\\s+[\\d.]+s)?\\s*$"]
        },
        {
          "id": "summary_passed",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["ok "],
          "lineRegex": ["^ok\\s+\\S+\\s+([\\d.]+s|\\(cached\\))$"]
        },
        {
          "id": "running",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["=== run"],
          "lineRegex": ["^=== RUN\\s+\\S+$"],
          "not": [ { "lineRegex": ["^(FAIL|ok)\\s"] } ]
        }
      ]
    },
    {
      "id": "swifttest",
      "kind": "task",
      "family": "tests",
      "displayName": "swift test",
      "rules": [
        {
          "id": "summary_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["executed", "failure"],
          "lineRegex": ["^\\s*Executed \\d+ tests?, with [1-9]\\d* failures?"]
        },
        {
          "id": "summary_passed",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["executed", "with 0 failures"],
          "lineRegex": ["^\\s*Executed \\d+ tests?, with 0 failures"]
        },
        {
          "id": "running",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["test case"],
          "lineRegex": ["^Test Case '.+' (started|passed|failed)"],
          "not": [ { "contains": ["executed"] } ]
        }
      ]
    },
    {
      "id": "cargotest",
      "kind": "task",
      "family": "tests",
      "displayName": "cargo test",
      "rules": [
        {
          "id": "result_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["test result: failed"],
          "lineRegex": ["^test result: FAILED\\. \\d+ passed; \\d+ failed"]
        },
        {
          "id": "result_ok",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["test result: ok"],
          "lineRegex": ["^test result: ok\\. \\d+ passed"]
        },
        {
          "id": "streaming",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["test "],
          "lineRegex": ["^test \\S+ \\.\\.\\. (ok|FAILED|ignored)$"],
          "not": [ { "contains": ["test result:"] } ]
        }
      ]
    },
    {
      "id": "cargo",
      "kind": "task",
      "family": "builds",
      "displayName": "Cargo",
      "progress": { "regex": "\\] (\\d+)/(\\d+)", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "compile_error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["error"],
          "lineRegex": ["^error(\\[E\\d+\\])?: .+$"]
        },
        {
          "id": "finished",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["finished"],
          "lineRegex": ["^\\s*Finished .* in ([\\d.]+s|\\d+m [\\d.]+s)$"]
        },
        {
          "id": "compiling",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "any": [
            { "contains": ["compiling "] },
            { "contains": ["checking "] },
            { "contains": ["downloading "] },
            { "contains": ["building ["] }
          ],
          "lineRegex": ["^\\s*(Compiling|Checking|Downloading|Building) .+$"],
          "not": [ { "lineRegex": ["^\\s*Finished .* in "] } ]
        }
      ]
    },
    {
      "id": "ninja",
      "kind": "task",
      "family": "builds",
      "displayName": "Ninja",
      "progress": { "regex": "^\\[(\\d+)/(\\d+)\\]", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "build_stopped",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["ninja: build stopped"],
          "lineRegex": ["^ninja: build stopped.*$"]
        },
        {
          "id": "step_failed",
          "state": "failed",
          "priority": 115,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["failed: "],
          "lineRegex": ["^FAILED: .+$"]
        },
        {
          "id": "stepping",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["["],
          "lineRegex": ["^\\[\\d+/\\d+\\] \\S+"],
          "not": [ { "contains": ["ninja: build stopped"] } ]
        }
      ]
    },
    {
      "id": "xcodebuild",
      "kind": "task",
      "family": "builds",
      "displayName": "xcodebuild",
      "rules": [
        {
          "id": "build_failed",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["failed **"],
          "lineRegex": ["^\\*\\* (BUILD|TEST|ARCHIVE|CLEAN) FAILED \\*\\*$"]
        },
        {
          "id": "build_succeeded",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["succeeded **"],
          "lineRegex": ["^\\*\\* (BUILD|TEST|ARCHIVE|CLEAN) SUCCEEDED \\*\\*$"]
        },
        {
          "id": "compiling",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(3)",
          "visibleWorking": true,
          "any": [
            { "contains": ["compileswift"] },
            { "contains": ["compilec "] },
            { "contains": ["swiftdriver"] },
            { "contains": ["codesign "] },
            { "contains": ["linking "] },
            { "contains": ["processinfoplistfile"] }
          ],
          "lineRegex": ["^(CompileSwift|CompileC|SwiftDriver|Ld|CodeSign|Linking|ProcessInfoPlistFile|CompileAssetCatalog)\\b"],
          "not": [ { "contains": ["succeeded **"] }, { "contains": ["failed **"] } ]
        }
      ]
    },
    {
      "id": "terraform",
      "kind": "task",
      "family": "infra",
      "displayName": "Terraform",
      "rules": [
        {
          "id": "error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["error:"],
          "lineRegex": ["^[│╷]? ?Error: .+$"]
        },
        {
          "id": "apply_complete",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "any": [
            { "contains": ["apply complete!"] },
            { "contains": ["destroy complete!"] }
          ],
          "lineRegex": ["^(Apply|Destroy) complete! Resources: \\d+ (added|destroyed)"]
        },
        {
          "id": "plan_complete",
          "state": "done",
          "priority": 105,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["plan:"],
          "lineRegex": ["^Plan: \\d+ to add, \\d+ to change, \\d+ to destroy\\.$"]
        },
        {
          "id": "enter_value",
          "state": "blocked",
          "priority": 100,
          "region": "bottom_non_empty_lines(1)",
          "visibleBlocker": true,
          "contains": ["enter a value"],
          "lineRegex": ["^\\s*Enter a value:\\s*$"]
        },
        {
          "id": "working",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "any": [
            { "contains": ["refreshing state"] },
            { "contains": ["still creating"] },
            { "contains": ["still modifying"] },
            { "contains": ["still destroying"] },
            { "contains": ["creating..."] },
            { "contains": ["modifying..."] },
            { "contains": ["destroying..."] }
          ],
          "lineRegex": ["(: (Creating|Modifying|Destroying|Reading)\\.\\.\\.|Still (creating|modifying|destroying)\\.\\.\\.|Refreshing state\\.\\.\\.)"],
          "not": [ { "contains": ["complete! resources:"] } ]
        }
      ]
    },
    {
      "id": "kubectl",
      "kind": "task",
      "family": "infra",
      "displayName": "kubectl",
      "rules": [
        {
          "id": "rolled_out",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["successfully rolled out"],
          "lineRegex": ["successfully rolled out$"]
        },
        {
          "id": "waiting",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["waiting for"],
          "lineRegex": ["^Waiting for (deployment|.*rollout)"],
          "not": [ { "contains": ["successfully rolled out"] } ]
        }
      ]
    },
    {
      "id": "docker",
      "kind": "task",
      "family": "infra",
      "displayName": "Docker",
      "rules": [
        {
          "id": "build_error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "any": [
            { "contains": ["error: failed to"] },
            { "contains": ["non-zero code"] }
          ],
          "lineRegex": ["(^ERROR: failed to (solve|build)|returned a non-zero code: \\d+)"]
        },
        {
          "id": "image_written",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "any": [
            { "contains": ["writing image sha256:"] },
            { "contains": ["successfully built"] },
            { "contains": ["successfully tagged"] }
          ],
          "lineRegex": ["(writing image sha256:|^Successfully (built|tagged) \\S+)"]
        },
        {
          "id": "building",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(3)",
          "visibleWorking": true,
          "any": [
            { "lineRegex": ["^#\\d+ (\\[|DONE|CACHED|extracting|sha256:)"] },
            { "lineRegex": ["^Step \\d+/\\d+ : .+$"] }
          ],
          "not": [
            { "contains": ["writing image sha256:"] },
            { "contains": ["successfully built"] },
            { "contains": ["successfully tagged"] },
            { "contains": ["error: failed to"] }
          ]
        }
      ]
    },
    {
      "id": "rsync",
      "kind": "task",
      "family": "transfers",
      "displayName": "rsync",
      "progress": { "regex": "\\s(\\d+)%\\s", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(6)",
          "contains": ["rsync error:"],
          "lineRegex": ["^rsync error: .+$"]
        },
        {
          "id": "totals",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["sent ", "received "],
          "lineRegex": ["^sent [\\d,.]+ bytes\\s+received [\\d,.]+ bytes\\s+[\\d,.]+ bytes/sec$"]
        },
        {
          "id": "progress",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["%"],
          "lineRegex": ["^\\s*[\\d,.]+[KMG]?\\s+\\d+%\\s+[\\d.]+[kKMG]?B/s\\s+[\\d:]+"],
          "not": [ { "contains": ["rsync error:"] } ]
        }
      ]
    },
    {
      "id": "wget",
      "kind": "task",
      "family": "transfers",
      "displayName": "wget",
      "progress": { "regex": "\\s(\\d+)%\\[", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["wget: "],
          "lineRegex": ["^wget: .+$"]
        },
        {
          "id": "saved",
          "state": "done",
          "priority": 110,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["saved ["],
          "lineRegex": ["saved \\[[\\d/]+\\]$"]
        },
        {
          "id": "progress",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["%["],
          "lineRegex": ["\\d+%\\[.*\\]\\s+[\\d.,]+[KMG]?\\s+[\\d.]+[KMG]?B/s"],
          "not": [ { "contains": ["saved ["] } ]
        }
      ]
    },
    {
      "id": "curl",
      "kind": "task",
      "family": "transfers",
      "displayName": "curl",
      "rules": [
        {
          "id": "error",
          "state": "failed",
          "priority": 120,
          "region": "bottom_non_empty_lines(4)",
          "contains": ["curl: ("],
          "lineRegex": ["^curl: \\(\\d+\\) .+$"]
        },
        {
          "id": "meter",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": [":"],
          "lineRegex": ["^\\s*\\d{1,3}\\s+[\\d.]+[kKMGT]?\\s+\\d{1,3}\\s+[\\d.]+[kKMGT]?\\s+\\d+\\s+\\d+\\s+[\\d.]+[kKMGT]?\\s+[\\d.]+[kKMGT]?\\s+[\\d:-]+\\s+[\\d:-]+\\s+[\\d:-]+"],
          "not": [ { "contains": ["curl: ("] } ]
        }
      ]
    },
    {
      "id": "scp",
      "kind": "task",
      "family": "transfers",
      "displayName": "scp",
      "progress": { "regex": "\\s(\\d+)%\\s", "region": "bottom_non_empty_lines(2)" },
      "rules": [
        {
          "id": "progress",
          "state": "working",
          "priority": 90,
          "region": "bottom_non_empty_lines(1)",
          "visibleWorking": true,
          "contains": ["eta"],
          "lineRegex": ["\\s\\d+%\\s+[\\d.]+[KMG]?B?\\s+[\\d.]+[KMG]?B/s\\s+([\\d:]+|--:--)( ETA)?"]
        }
      ]
    }
  ]
}
"""#
}
