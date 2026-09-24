#!/usr/bin/env python3
"""Write Contents/Resources/Metadata.appintents for aiFlow's App Intents.

Shortcuts, Spotlight and Siri learn an app's actions from this folder, which
Xcode's appintentsmetadataprocessor normally generates. This Mac builds with
Command Line Tools only (build-local.sh), which don't ship that tool — so the
same JSON (format 3.0, as found in Apple's own apps) is written here from the
INTENTS table below. Keep it in sync with AppIntents.swift: type
names, @Parameter property names, titles and value types must match, or
Shortcuts shows the action but can't run it.

Mangled Swift type names are read from the linked binary (nm), never
computed: Swift compresses repeated words ("FinderFlowApp" -> "0aB3App").

usage: make_metadata.py <path/to/executable> <path/to/Contents/Resources>
       make_metadata.py --check <path/to/executable>   (only verify types exist)
"""
import json
import os
import subprocess
import sys

MODULE = "FinderFlow"

# Value types (LinkServices wire format, as used by Apple's apps).
STRING = {"primitive": {"wrapper": {"typeIdentifier": 0}}}
DATE = {"primitive": {"wrapper": {"typeIdentifier": 8}}}
FILE = {"intents": {"wrapper": {"typeIdentifier": 12}}}
FILES = {"array": {"wrapper": {"capabilities": 3, "memberValueType": FILE}}}


def text(s):
    return {"alternatives": [], "key": s}


def param(name, title, vtype, *, optional=False, description=None, file_types=None,
          is_input=False):
    p = {
        "capabilities": 0,
        "dynamicOptionsSupport": 0,
        "inputConnectionBehavior": 2 if is_input else 0,
        "isInput": is_input,
        "isOptional": optional,
        "name": name,
        "resolvableInputTypes": [{"kindValue": 0, "valueType": STRING}] if vtype is STRING else [],
        "title": text(title),
        "typeSpecificMetadata": [],
        "valueType": vtype,
    }
    if description:
        p["parameterDescription"] = text(description)
    if file_types:
        p["typeSpecificMetadata"] = [
            "LNValueTypeMetadataKeyFileSupportedTypes",
            {"array": {"elements": [{"string": {"wrapper": t}} for t in file_types]}},
        ]
    return p


# Mirrors AppIntents.swift.
INTENTS = [
    {
        "type": "OpenTodayIntent",
        "title": "Open Today",
        "description": "Shows what needs you today in aiFlow: tasks, reminders, reviews, mail waiting and what Folder Rules sorted.",
        "keywords": ["today", "agenda", "tasks", "reminders", "danas"],
        "openAppWhenRun": True,
        "params": [],
    },
    {
        "type": "CombinePDFsIntent",
        "title": "Combine into PDF",
        "description": "Combines PDFs and images, in the order given, into one PDF. Runs on this Mac.",
        "keywords": ["pdf", "merge", "combine", "images", "spoji"],
        "params": [
            param("files", "Files", FILES, description="PDFs and images, in order.",
                  file_types=["com.adobe.pdf", "public.image"], is_input=True),
            param("name", "File Name", STRING, optional=True, description="Name of the new PDF (optional)."),
        ],
        "summary": ("Combine ${files} into PDF", ["files"], ["name"]),
        "output": FILE,
    },
    {
        "type": "MakePDFSearchableIntent",
        "title": "Make PDF Searchable",
        "description": "Recognizes text on scanned pages on this Mac (nothing is uploaded) and returns a searchable copy.",
        "keywords": ["pdf", "ocr", "scan", "text", "searchable"],
        "params": [param("file", "PDF", FILE, file_types=["com.adobe.pdf"], is_input=True)],
        "summary": ("Make ${file} searchable", ["file"], []),
        "output": FILE,
    },
    {
        "type": "CompressPDFIntent",
        "title": "Compress PDF",
        "description": "Re-saves the PDF's images as JPEG sized for screens. Returns the original when it can't get smaller.",
        "keywords": ["pdf", "compress", "shrink", "smaller", "size"],
        "params": [param("file", "PDF", FILE, file_types=["com.adobe.pdf"], is_input=True)],
        "summary": ("Compress ${file}", ["file"], []),
        "output": FILE,
    },
    {
        "type": "SortFolderNowIntent",
        "title": "Sort Folder Now",
        "description": "Applies the folder's aiFlow auto-sort rules to every file in it now, like Preview ▸ Sort N Files. Moves are undoable in Today and the Folder Rules window.",
        "keywords": ["sort", "organize", "folder rules", "hazel", "sredi"],
        "params": [param("folder", "Folder", FILE, file_types=["public.folder"])],
        "summary": ("Sort ${folder} now", ["folder"], []),
        "output": STRING,
    },
    {
        "type": "AddWorkspaceTaskIntent",
        "title": "Add Task",
        "description": "Adds a task to the aiFlow workspace of a file or folder, linked to that file. A folder that isn't a workspace yet becomes one.",
        "keywords": ["task", "todo", "workspace", "zadatak"],
        "params": [
            param("taskTitle", "Task", STRING),
            param("file", "File or Folder", FILE, file_types=["public.item"]),
            param("dueDate", "Due Date", DATE, optional=True),
        ],
        "summary": ("Add task ${taskTitle} to ${file}", ["taskTitle", "file"], ["dueDate"]),
        "output": STRING,
    },
]

APP_SHORTCUTS_PROVIDER = "AiFlowAppShortcuts"
AUTO_SHORTCUTS = [
    {
        "actionIdentifier": "OpenTodayIntent",
        "phrases": [
            "Open Today in ${applicationName}",
            "What's due in ${applicationName}",
            "Show my ${applicationName} day",
        ],
        "shortTitle": "Today",
        "systemImageName": "sun.max",
    }
]

WILDCARD = {"LNPlatformNameWildcard": {"introducedVersion": "*"}}


def mangled_names(binary):
    """{"OpenTodayIntent": "10FinderFlow15OpenTodayIntentV", ...} from the
    nominal type descriptors ($s…VMn) in the executable's symbol table."""
    out = subprocess.run(["nm", binary], capture_output=True, text=True, check=True).stdout
    syms = [line.split()[-1] for line in out.splitlines() if line.endswith("VMn")]
    syms = [s[1:] if s.startswith("_") else s for s in syms]
    dem = subprocess.run(["swift", "demangle", "--compact"], input="\n".join(syms),
                         capture_output=True, text=True, check=True).stdout.splitlines()
    names = {}
    prefix = "nominal type descriptor for %s." % MODULE
    for sym, d in zip(syms, dem):
        if d.startswith(prefix):
            names[d[len(prefix):]] = sym[len("$s"):-len("Mn")]
    return names


def action(spec, mangled):
    open_app = spec.get("openAppWhenRun", False)
    a = {
        "assistantDefinedSchemaTraits": [],
        "assistantDefinedSchemas": [],
        "authenticationPolicy": 0,
        "availabilityAnnotations": WILDCARD,
        "descriptionMetadata": {
            "descriptionText": text(spec["description"]),
            "searchKeywords": [text(k) for k in spec.get("keywords", [])],
        },
        "effectiveBundleIdentifiers": [],
        "fullyQualifiedTypeName": "%s.%s" % (MODULE, spec["type"]),
        "identifier": spec["type"],
        "isAuthPolExplicit": False,
        "isDiscoverable": True,
        "mangledTypeName": mangled,
        "mangledTypeNameByBundleIdentifier": {},
        "mangledTypeNameByBundleIdentifierV2": {},
        "mangledTypeNameV2": mangled,
        "openAppWhenRun": open_app,
        "outputFlags": 0,
        "parameters": spec["params"],
        "presentationStyle": 0,
        "requiredCapabilities": [],
        "supportedModes": 2 if open_app else 1,
        "systemProtocolMetadata": [],
        "systemProtocolMetadataV2": [],
        "systemProtocols": [],
        "title": text(spec["title"]),
        "typeSpecificMetadata": [],
        "visibilityMetadata": {"assistantOnly": False, "isDiscoverable": True},
    }
    if "output" in spec:
        a["outputType"] = spec["output"]
    if "summary" in spec:
        fmt, ids, others = spec["summary"]
        a["actionConfiguration"] = {"actionSummary": {"wrapper": {
            "otherParameterIdentifiers": others,
            "summaryString": {"formatString": fmt, "parameterIdentifiers": ids},
        }}}
    return a


def build(binary):
    names = mangled_names(binary)
    wanted = [s["type"] for s in INTENTS] + [APP_SHORTCUTS_PROVIDER]
    missing = [t for t in wanted if t not in names]
    if missing:
        sys.exit("make_metadata: not in %s: %s (renamed in AppIntents.swift?)" % (binary, ", ".join(missing)))
    return {
        "actions": {s["type"]: action(s, names[s["type"]]) for s in INTENTS},
        "assistantEntities": [],
        "assistantIntentNegativePhrases": [],
        "assistantIntents": [],
        "autoShortcutProviderMangledName": names[APP_SHORTCUTS_PROVIDER],
        "autoShortcuts": [{
            "actionIdentifier": s["actionIdentifier"],
            "availabilityAnnotations": WILDCARD,
            "phraseTemplates": [text(p) for p in s["phrases"]],
            "shortTitle": text(s["shortTitle"]),
            "systemImageName": s["systemImageName"],
        } for s in AUTO_SHORTCUTS],
        "entities": {},
        "enums": [],
        "generator": {"name": "xcode-tools", "version": "*"},
        "negativePhrases": [],
        "queries": {},
        "shortcutTileColor": 14,
        "version": 1,
    }


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        build(sys.argv[2])
        print("    App Intents types found")
        return
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    binary, resources = sys.argv[1], sys.argv[2]
    data = build(binary)
    out = os.path.join(resources, "Metadata.appintents")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "extract.actionsdata"), "w") as f:
        json.dump(data, f, indent=2, sort_keys=True, ensure_ascii=False)
    with open(os.path.join(out, "version.json"), "w") as f:
        json.dump({"toolsVersion": "*", "version": "3.0"}, f, indent=2)
    print("    Metadata.appintents: %d actions, %d App Shortcut(s)" % (len(data["actions"]), len(AUTO_SHORTCUTS)))


if __name__ == "__main__":
    main()
