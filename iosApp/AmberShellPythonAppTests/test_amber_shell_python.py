"""Host-side regression tests for the bundled AmberShell Python helper.

The iOS bridge embeds CPython, but the helper's AST and module-lifetime rules
are deterministic and can be tested without an iOS simulator.  Keep these
tests outside ``AmberShellPythonApp`` so they are not copied into the app
bundle.
"""

import importlib.util
import pathlib
import unittest


_HELPER_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "AmberShellPythonApp"
    / "amber_shell_python.py"
)
_SPEC = importlib.util.spec_from_file_location("amber_shell_python", _HELPER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_HELPER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_HELPER)


class AmberShellPythonTests(unittest.TestCase):
    def execute(self, source, stdin=""):
        return _HELPER.execute(source, stdin)

    def assertModuleMutationRejected(self, source):
        exit_code, stdout, stderr = self.execute(source, "unique-secret\n")
        self.assertEqual(exit_code, 2)
        self.assertEqual(stdout, "")
        self.assertIn("module attributes are read-only", stderr)

    def test_allowlisted_module_attribute_assignment_is_rejected(self):
        self.assertModuleMutationRejected(
            "import json; json.amber_state = input()"
        )
        exit_code, stdout, stderr = self.execute(
            "import json\n"
            "try:\n"
            "    print(json.amber_state)\n"
            "except AttributeError:\n"
            "    print('missing')"
        )
        self.assertEqual((exit_code, stdout, stderr), (0, "missing\n", ""))

    def test_allowlisted_module_attribute_augassign_and_delete_are_rejected(self):
        self.assertModuleMutationRejected("import math; math.pi = 0")
        self.assertModuleMutationRejected("import math; math.pi += 1")
        self.assertModuleMutationRejected("import json; del json.dumps")
        exit_code, stdout, stderr = self.execute(
            "import math; print(math.pi == 3.141592653589793)"
        )
        self.assertEqual((exit_code, stdout, stderr), (0, "True\n", ""))

    def test_module_aliases_cannot_be_used_to_mutate_module_state(self):
        self.assertModuleMutationRejected(
            "import json as payload; payload.amber_state = input()"
        )
        self.assertModuleMutationRejected(
            "import json\n"
            "alias = json\n"
            "alias.amber_state = input()"
        )
        self.assertModuleMutationRejected(
            "from json import decoder\n"
            "decoder.amber_state = input()"
        )

        # The AST check intentionally stays conservative, so also exercise the
        # runtime read-only proxy with an indirect module-returning expression.
        exit_code, stdout, stderr = self.execute(
            "import json\n"
            "def imported_module():\n"
            "    return json\n"
            "imported_module().amber_state = input()",
            "unique-secret\n",
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("module attributes are read-only", stderr)

    def test_allowlisted_module_objects_are_not_retained_between_jobs(self):
        exit_code, stdout, stderr = self.execute(
            "import json; print(json.dumps({'ok': True}))"
        )
        self.assertEqual((exit_code, stdout, stderr), (0, '{"ok": true}\n', ""))
        self.assertNotIn("json", _HELPER._sys.modules)

        exit_code, stdout, stderr = self.execute(
            "import json; print(json.dumps({'fresh': True}))"
        )
        self.assertEqual((exit_code, stdout, stderr), (0, '{"fresh": true}\n', ""))
        self.assertNotIn("json", _HELPER._sys.modules)

    def test_function_definitions_and_imports_continue_to_work(self):
        exit_code, stdout, stderr = self.execute(
            "from math import factorial\n"
            "def twice(value):\n"
            "    return factorial(value) * 2\n"
            "print(twice(6))"
        )
        self.assertEqual((exit_code, stdout, stderr), (0, "1440\n", ""))


if __name__ == "__main__":
    unittest.main()
