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

    def assertStaticCostRejected(self, source, reason):
        exit_code, stdout, stderr = self.execute(source)
        self.assertEqual(exit_code, 2)
        self.assertEqual(stdout, "")
        self.assertIn("AmberShell Python rejected: " + reason, stderr)

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

    def test_static_guard_rejects_direct_huge_c_level_allocations(self):
        # Keep dangerous expressions inside an uncalled function.  These cases
        # therefore stay safe even when this regression test is run against a
        # helper that does not yet reject them before execution.
        cases = (
            ('return "a" * 1048577', "static text result exceeds"),
            ('return "a" * (2 ** 30)', "static text result exceeds"),
            ("return [0] * 100001", "static collection result exceeds"),
            ("return [0] * (10 ** 9)", "static collection result exceeds"),
            ("return 2 ** 1000001", "static integer result exceeds"),
            ("return pow(2, 1000001)", "static integer result exceeds"),
            ("return (2 ** 500000) ** 3", "static integer result exceeds"),
            ("return list(range(100001))", "materialized range exceeds"),
            ("return tuple(range(10 ** 9))", "materialized range exceeds"),
            ("return [*range(100001)]", "materialized range exceeds"),
            ("return dict.fromkeys(range(100001))", "materialized range exceeds"),
            ("return bytes(1048577)", "static text result exceeds"),
            ("return bytes(range(10 ** 9))", "materialized range exceeds"),
            (
                "return dict(enumerate(range(10 ** 9)))",
                "materialized range exceeds",
            ),
            ('return ("a" + "b") * (10 ** 9)', "static text result exceeds"),
            ("return str(1) * (10 ** 9)", "static text result exceeds"),
            (
                'return str("a" + "b") * (10 ** 9)',
                "static text result exceeds",
            ),
            (
                'return "a" * ((2 ** 30) + 1)',
                "static text result exceeds",
            ),
            (
                "return list(range((10 ** 9) + 1))",
                "materialized range exceeds",
            ),
            ("return bytes((10 ** 9) + 1)", "static text result exceeds"),
        )
        for expression, reason in cases:
            with self.subTest(expression=expression):
                self.assertStaticCostRejected(
                    "def never_called():\n    " + expression,
                    reason,
                )

    def test_static_guard_rejects_oversized_source_literals_and_asts(self):
        self.assertStaticCostRejected(
            "#" * 262145,
            "source exceeds 262144 UTF-8 bytes",
        )
        self.assertStaticCostRejected(
            "value = " + repr("x" * 131073),
            "literal data exceeds 131072 bytes",
        )
        self.assertStaticCostRejected(
            "\n".join("x = 0" for _ in range(5001)),
            "AST exceeds 20000 nodes",
        )
        self.assertStaticCostRejected(
            "value = " + "-" * 101 + "1",
            "AST depth exceeds 100",
        )

    def test_static_guard_allows_reasonable_programs_at_each_cost_limit(self):
        exit_code, stdout, stderr = self.execute(
            "text = 'a' * 1048576\n"
            "items = [0] * 100000\n"
            "number = 2 ** 999999\n"
            "values = list(range(100000))\n"
            "print(len(text), len(items), number.bit_length(), len(values))"
        )
        self.assertEqual(
            (exit_code, stdout, stderr),
            (0, "1048576 100000 1000000 100000\n", ""),
        )

        structural_cases = (
            "#" * 262144,
            "value = " + repr("x" * 131072),
            "\n".join("x = 0" for _ in range(4999)),
            "value = " + "-" * 97 + "1",
        )
        for source in structural_cases:
            with self.subTest(source_length=len(source)):
                self.assertEqual(self.execute(source), (0, "", ""))

    def test_static_guard_allows_new_materializers_and_sequences_at_limits(self):
        exit_code, stdout, stderr = self.execute(
            "raw = bytes(map(lambda value: 0, range(100000)))\n"
            "zeroes = bytes(1048576)\n"
            "mapping = dict(enumerate(range(100000)))\n"
            "joined = ('a' + 'b') * 524288\n"
            "rendered = str(1) * 1048576\n"
            "composed = str('a' + 'b') * 524288\n"
            "cancelled_text = 'a' * ((2 ** 30) - (2 ** 30) + 1048576)\n"
            "cancelled_values = list(\n"
            "    range((10 ** 9) - (10 ** 9) + 100000)\n"
            ")\n"
            "cancelled_bytes = bytes(\n"
            "    (10 ** 9) - (10 ** 9) + 1048576\n"
            ")\n"
            "print(len(raw), len(zeroes), len(mapping), len(joined), "
            "len(rendered), len(composed), len(cancelled_text), "
            "len(cancelled_values), len(cancelled_bytes))"
        )
        self.assertEqual(
            (exit_code, stdout, stderr),
            (
                0,
                "100000 1048576 100000 1048576 1048576 1048576 "
                "1048576 100000 1048576\n",
                "",
            ),
        )


if __name__ == "__main__":
    unittest.main()
