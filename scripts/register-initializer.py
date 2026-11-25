"""Add one MaciPEAK component to the staged Unity Mono player startup tables."""

import json
from pathlib import Path
import sys


def register(data, component, when):
    name = "MaciPEAK." + component
    filename = name + ".dll"
    assemblies_path = data / "ScriptingAssemblies.json"
    startup_path = data / "RuntimeInitializeOnLoads.json"
    assemblies = json.loads(assemblies_path.read_bytes())
    startup = json.loads(startup_path.read_bytes())
    names, types = assemblies["names"], assemblies["types"]
    if len(names) != len(types) or names.count("Assembly-CSharp.dll") != 1:
        raise ValueError("Unexpected Unity scripting assembly table")
    kind = types[names.index("Assembly-CSharp.dll")]
    entry = dict(assemblyName=name, nameSpace="MaciPEAK", className=component,
                 methodName="Initialize", loadTypes={"after": 0, "before": 1}[when], isUnityClass=False)
    matches = [row for row in startup["root"] if row["assemblyName"] == name]
    if filename in names or matches:
        if names.count(filename) == 1 and types[names.index(filename)] == kind and matches == [entry]:
            return
        raise ValueError("Unexpected existing registration for " + name)
    names.append(filename)
    types.append(kind)
    startup["root"].append(entry)
    for path, table in ((assemblies_path, assemblies), (startup_path, startup)):
        path.write_text(json.dumps(table, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    register(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
