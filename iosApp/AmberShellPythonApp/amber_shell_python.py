"""AmberShell's deliberately small, non-sandbox Python execution helper.

This module is part of the app bundle. The Objective-C bridge initializes
CPython with an isolated path configuration and calls :func:`execute` for
each foreground command while retaining one interpreter for the process.
"""

import ast as _ast
import builtins as _builtins
import sys as _sys
import traceback as _traceback
import types as _types


_MAX_STDIN_BYTES = 64 * 1024
_MAX_OUTPUT_BYTES = 128 * 1024
_OUTPUT_LIMIT_ERROR = "AmberShell Python output exceeded 131072 UTF-8 bytes.\n"

# These pre-execution limits reject statically obvious allocation bombs before
# CPython enters C helpers that output limits or cooperative tracing cannot
# interrupt.
# They reduce accidental resource exhaustion; they are not a memory sandbox.
_MAX_SOURCE_BYTES = 256 * 1024
_MAX_AST_NODES = 20_000
_MAX_AST_DEPTH = 100
_MAX_LITERAL_BYTES = 128 * 1024
_MAX_STATIC_TEXT_BYTES = 1024 * 1024
_MAX_STATIC_COLLECTION_ITEMS = 100_000
_MAX_STATIC_INTEGER_BITS = 1_000_000
_MAX_MATERIALIZED_RANGE_ITEMS = 100_000

# These are intentionally explicit. They are selected for deterministic,
# non-I/O data processing; adding a module requires an audit of its imports
# and APIs. The list is not a security sandbox.
_ALLOWED_MODULES = frozenset(
    {
        "array",
        "base64",
        "bisect",
        "calendar",
        "collections",
        "collections.abc",
        "dataclasses",
        "datetime",
        "decimal",
        "enum",
        "fractions",
        "functools",
        "hashlib",
        "heapq",
        "itertools",
        "json",
        "math",
        "pprint",
        "re",
        "statistics",
        "textwrap",
        "unicodedata",
    }
)

_FORBIDDEN_NAMES = frozenset(
    {
        "builtins",
        "compile",
        "ctypes",
        "delattr",
        "eval",
        "exec",
        "getattr",
        "globals",
        "importlib",
        "inspect",
        "locals",
        "marshal",
        "open",
        "os",
        "pathlib",
        "pickle",
        "pip",
        "setattr",
        "socket",
        "subprocess",
        "sys",
        "types",
        "modules",
        "vars",
        "bltns",
    }
)


class _RejectedSource(Exception):
    pass


class _LimitedTextStream:
    encoding = "utf-8"
    errors = "backslashreplace"

    def __init__(self, limit):
        self._limit = limit
        self._size = 0
        self._chunks = []
        self.truncated = False

    def write(self, value):
        if not isinstance(value, str):
            value = str(value)
        if self._size >= self._limit:
            self.truncated = True
            return len(value)

        encoded = value.encode("utf-8", "backslashreplace")
        remaining = self._limit - self._size
        if len(encoded) > remaining:
            self.truncated = True
        piece = encoded[:remaining].decode("utf-8", "ignore")
        if piece:
            self._chunks.append(piece)
            self._size += len(piece.encode("utf-8"))
        return len(value)

    def flush(self):
        return None

    def isatty(self):
        return False

    def getvalue(self):
        return "".join(self._chunks)


class _InputStream:
    encoding = "utf-8"
    errors = "strict"

    def __init__(self, value):
        self._value = value
        self._offset = 0

    def read(self, size=-1):
        if size is None or size < 0:
            size = len(self._value) - self._offset
        end = min(len(self._value), self._offset + size)
        value = self._value[self._offset : end]
        self._offset = end
        return value

    def readline(self, size=-1):
        if self._offset >= len(self._value):
            return ""
        newline = self._value.find("\n", self._offset)
        end = len(self._value) if newline < 0 else newline + 1
        if size is not None and size >= 0:
            end = min(end, self._offset + size)
        value = self._value[self._offset : end]
        self._offset = end
        return value

    def isatty(self):
        return False


def _is_allowlisted_module_name(name):
    """Return whether *name* belongs to one of the modules we expose.

    Importing a module normally puts both the requested module and its
    implementation submodules in ``sys.modules``.  Treating the whole
    family as one unit is important here: dropping only ``json`` would leave
    ``json.encoder`` (and any state it carries) alive for the next job.
    """
    return any(
        name == allowed or name.startswith(allowed + ".")
        for allowed in _ALLOWED_MODULES
    )


class _ReadOnlyModule:
    """Expose an allowlisted module without exposing mutation operations."""

    __slots__ = ("_module",)

    def __init__(self, module):
        object.__setattr__(self, "_module", module)

    def __getattr__(self, name):
        module = object.__getattribute__(self, "_module")
        value = getattr(module, name)
        if isinstance(value, _types.ModuleType) and _is_allowlisted_module_name(
            value.__name__
        ):
            return _ReadOnlyModule(value)
        return value

    def __setattr__(self, name, value):
        module = object.__getattribute__(self, "_module")
        raise AttributeError(
            "allowlisted module attributes are read-only: "
            + module.__name__
            + "."
            + name
        )

    def __delattr__(self, name):
        module = object.__getattribute__(self, "_module")
        raise AttributeError(
            "allowlisted module attributes are read-only: "
            + module.__name__
            + "."
            + name
        )


def _safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    if level != 0 or name not in _ALLOWED_MODULES:
        raise ImportError("AmberShell Python import is not allowlisted: " + repr(name))
    fromlist = fromlist or ()
    if any(
        isinstance(item, str) and (item.startswith("__") or item.endswith("__"))
        for item in fromlist
    ):
        raise ImportError("AmberShell Python import name cannot be a dunder.")
    module = _ORIGINAL_IMPORT(name, globals, locals, fromlist, level)
    return _ReadOnlyModule(module)


_ORIGINAL_IMPORT = _builtins.__import__


# ``ast`` imports a few standard-library modules before the first user job.
# Keep those interpreter-owned modules intact while making every module first
# imported by a job ephemeral.  This avoids disturbing CPython internals while
# still preventing a user-imported module (and its submodules) from surviving
# into the next job.
_BASELINE_ALLOWED_MODULES = {
    name: module
    for name, module in tuple(_sys.modules.items())
    if module is not None and _is_allowlisted_module_name(name)
}
_BASELINE_ALLOWED_MODULE_STATES = {
    name: dict(module.__dict__)
    for name, module in _BASELINE_ALLOWED_MODULES.items()
}


def _reset_allowlisted_modules():
    """Restore interpreter-owned modules and discard job-imported modules."""
    for name in tuple(_sys.modules):
        if not _is_allowlisted_module_name(name):
            continue
        baseline = _BASELINE_ALLOWED_MODULES.get(name)
        if baseline is None:
            _sys.modules.pop(name, None)
            continue
        if _sys.modules.get(name) is not baseline:
            _sys.modules[name] = baseline

    for name, module in _BASELINE_ALLOWED_MODULES.items():
        state = _BASELINE_ALLOWED_MODULE_STATES[name]
        module_dict = module.__dict__
        for key in tuple(module_dict):
            if key not in state:
                del module_dict[key]
        module_dict.update(state)


def _safe_input(prompt=""):
    if prompt:
        _sys.stdout.write(prompt)
        _sys.stdout.flush()
    value = _sys.stdin.readline()
    if value == "":
        raise EOFError("EOF while reading AmberShell Python stdin")
    return value[:-1] if value.endswith("\n") else value


def _safe_builtins():
    names = (
        "abs",
        "all",
        "any",
        "ascii",
        "bin",
        "bool",
        "bytes",
        "callable",
        "complex",
        "dict",
        "divmod",
        "enumerate",
        "filter",
        "float",
        "format",
        "frozenset",
        "hash",
        "hex",
        "int",
        "isinstance",
        "issubclass",
        "iter",
        "len",
        "list",
        "map",
        "max",
        "min",
        "next",
        "object",
        "oct",
        "ord",
        "pow",
        "print",
        "range",
        "repr",
        "reversed",
        "round",
        "set",
        "slice",
        "sorted",
        "str",
        "sum",
        "tuple",
        "type",
        "zip",
        "BaseException",
        "Exception",
        "ArithmeticError",
        "AssertionError",
        "AttributeError",
        "EOFError",
        "IndexError",
        "KeyError",
        "LookupError",
        "NameError",
        "RuntimeError",
        "StopIteration",
        "TypeError",
        "ValueError",
        "ZeroDivisionError",
    )
    result = {name: getattr(_builtins, name) for name in names}
    result["__import__"] = _safe_import
    result["input"] = _safe_input
    return result


_ALLOWED_AST_NODES = (
    _ast.Add,
    _ast.And,
    _ast.Assert,
    _ast.Assign,
    _ast.Attribute,
    _ast.AugAssign,
    _ast.BinOp,
    _ast.BitAnd,
    _ast.BitOr,
    _ast.BitXor,
    _ast.BoolOp,
    _ast.Break,
    _ast.Call,
    _ast.Compare,
    _ast.comprehension,
    _ast.Constant,
    _ast.Continue,
    _ast.Del,
    _ast.Delete,
    _ast.Dict,
    _ast.DictComp,
    _ast.Div,
    _ast.Eq,
    _ast.Expr,
    _ast.FloorDiv,
    _ast.For,
    _ast.FormattedValue,
    _ast.FunctionDef,
    _ast.GeneratorExp,
    _ast.Gt,
    _ast.GtE,
    _ast.If,
    _ast.IfExp,
    _ast.Import,
    _ast.ImportFrom,
    _ast.In,
    _ast.Index,
    _ast.Is,
    _ast.IsNot,
    _ast.keyword,
    _ast.Lambda,
    _ast.List,
    _ast.ListComp,
    _ast.Load,
    _ast.Lt,
    _ast.LtE,
    _ast.MatMult,
    _ast.Mod,
    _ast.Mult,
    _ast.Name,
    _ast.NamedExpr,
    _ast.Module,
    _ast.Not,
    _ast.NotEq,
    _ast.NotIn,
    _ast.Or,
    _ast.Pass,
    _ast.Pow,
    _ast.Raise,
    _ast.Return,
    _ast.Set,
    _ast.SetComp,
    _ast.Slice,
    _ast.Store,
    _ast.Sub,
    _ast.Subscript,
    _ast.Try,
    _ast.Tuple,
    _ast.UnaryOp,
    _ast.UAdd,
    _ast.USub,
    _ast.While,
    _ast.With,  # rejected below; retained for a precise error message
    _ast.Yield,  # rejected below; retained for a precise error message
    _ast.JoinedStr,
    _ast.alias,
    _ast.arguments,
    _ast.arg,
    _ast.ExceptHandler,
    _ast.Starred,
)


def _is_dunder(name):
    return name.startswith("_")


def _attribute_root(node):
    """Find the name at the root of a dotted/module-derived expression."""
    while isinstance(node, (_ast.Attribute, _ast.Call, _ast.Subscript)):
        if isinstance(node, _ast.Attribute):
            node = node.value
        elif isinstance(node, _ast.Call):
            node = node.func
        else:
            node = node.value
    return node.id if isinstance(node, _ast.Name) else None


def _attribute_path(node):
    parts = []
    while isinstance(node, _ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, _ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


def _target_names(node):
    if isinstance(node, _ast.Name):
        return {node.id}
    if isinstance(node, (_ast.Tuple, _ast.List)):
        names = set()
        for element in node.elts:
            names.update(_target_names(element))
        return names
    return set()


def _module_target_bindings(target, value, module_bindings):
    if isinstance(target, _ast.Name):
        return {target.id} if _is_module_reference(value, module_bindings) else set()
    if isinstance(target, (_ast.Tuple, _ast.List)) and isinstance(
        value, (_ast.Tuple, _ast.List)
    ):
        bindings = set()
        for target_element, value_element in zip(target.elts, value.elts):
            bindings.update(
                _module_target_bindings(
                    target_element, value_element, module_bindings
                )
            )
        return bindings
    return set()


def _is_module_reference(node, module_bindings):
    root = _attribute_root(node)
    return root in module_bindings


def _module_bindings(tree):
    """Collect module names and conservative aliases from the source tree."""
    bindings = set()
    for node in _ast.walk(tree):
        if isinstance(node, _ast.Import):
            for alias in node.names:
                bindings.add(alias.asname or alias.name.split(".", 1)[0])
        elif isinstance(node, _ast.ImportFrom):
            for alias in node.names:
                if alias.name != "*":
                    # A from-import can expose a submodule (for example,
                    # ``from collections import abc``).  Conservatively mark
                    # every imported name so aliases cannot become writable
                    # module handles through a later refactor.
                    bindings.add(alias.asname or alias.name)

    changed = True
    while changed:
        changed = False
        for node in _ast.walk(tree):
            if isinstance(node, _ast.Assign):
                for target in node.targets:
                    if _is_module_reference(node.value, bindings):
                        new_names = _target_names(target)
                    else:
                        new_names = _module_target_bindings(
                            target, node.value, bindings
                        )
                    new_names -= bindings
                    if new_names:
                        bindings.update(new_names)
                        changed = True
            elif isinstance(node, _ast.NamedExpr) and _is_module_reference(
                node.value, bindings
            ):
                new_names = _target_names(node.target) - bindings
                if new_names:
                    bindings.update(new_names)
                    changed = True
    return bindings


def _reject_module_attribute_mutations(tree, module_bindings):
    for node in _ast.walk(tree):
        if not isinstance(node, (_ast.Attribute, _ast.Subscript)):
            continue
        if not isinstance(node.ctx, (_ast.Store, _ast.Del)):
            continue
        if _attribute_root(node) not in module_bindings:
            continue
        path = _attribute_path(node) or "module"
        raise _RejectedSource(
            "allowlisted module attributes are read-only: " + path
        )


def _clamp_integer(value, cap):
    if value > cap:
        return cap + 1, False
    if value < -cap:
        return -cap - 1, False
    return value, True


def _static_integer(node, cap):
    """Return a bounded integer value for a small constant expression.

    The boolean indicates whether the returned value is exact.  Inexact
    values retain only their sign and the fact that they exceeded *cap*; this
    helper never constructs the huge integer it is intended to detect.
    """
    if isinstance(node, _ast.Constant) and isinstance(node.value, int):
        return _clamp_integer(node.value, cap)

    if isinstance(node, _ast.UnaryOp) and isinstance(
        node.op, (_ast.UAdd, _ast.USub)
    ):
        result = _static_integer(node.operand, cap)
        if result is None:
            return None
        value, exact = result
        if isinstance(node.op, _ast.USub):
            value = -value
        return value, exact

    if not isinstance(node, _ast.BinOp):
        return None
    left = _static_integer(node.left, cap)
    right = _static_integer(node.right, cap)
    if left is None or right is None:
        return None
    left_value, left_exact = left
    right_value, right_exact = right

    if not left_exact or not right_exact:
        if isinstance(node.op, _ast.Add):
            if not left_exact and not right_exact:
                if (left_value > 0) == (right_value > 0):
                    return left_value, False
            elif not left_exact and (
                (left_value > 0 and right_value >= 0)
                or (left_value < 0 and right_value <= 0)
            ):
                return left_value, False
            elif not right_exact and (
                (right_value > 0 and left_value >= 0)
                or (right_value < 0 and left_value <= 0)
            ):
                return right_value, False
            return None

        if isinstance(node.op, _ast.Sub):
            if not left_exact and not right_exact:
                if (left_value > 0) != (right_value > 0):
                    return left_value, False
            elif not left_exact and (
                (left_value > 0 and right_value <= 0)
                or (left_value < 0 and right_value >= 0)
            ):
                return left_value, False
            elif not right_exact and (
                (right_value > 0 and left_value <= 0)
                or (right_value < 0 and left_value >= 0)
            ):
                sign = -1 if right_value > 0 else 1
                return sign * (cap + 1), False
            return None

        if isinstance(node.op, _ast.Mult):
            if (left_exact and left_value == 0) or (
                right_exact and right_value == 0
            ):
                return 0, True
            sign = -1 if (left_value < 0) != (right_value < 0) else 1
            return sign * (cap + 1), False

        if (
            isinstance(node.op, _ast.FloorDiv)
            and not left_exact
            and right_exact
            and abs(right_value) == 1
        ):
            sign = -1 if (left_value < 0) != (right_value < 0) else 1
            return sign * (cap + 1), False

        if isinstance(node.op, _ast.Pow):
            if right_exact:
                if right_value < 0:
                    return None
                if right_value == 0:
                    return 1, True
                if not left_exact:
                    sign = -1 if left_value < 0 and right_value % 2 else 1
                    return sign * (cap + 1), False
            elif right_value > 0:
                if left_exact and left_value in {0, 1}:
                    return left_value, True
                if left_value > 1:
                    return cap + 1, False
            return None

        return None

    try:
        if isinstance(node.op, _ast.Add):
            value = left_value + right_value
        elif isinstance(node.op, _ast.Sub):
            value = left_value - right_value
        elif isinstance(node.op, _ast.Mult):
            value = left_value * right_value
        elif isinstance(node.op, _ast.FloorDiv):
            value = left_value // right_value
        elif isinstance(node.op, _ast.Mod):
            value = left_value % right_value
        elif isinstance(node.op, _ast.Pow):
            if right_value < 0:
                return None
            if abs(left_value) >= 2 and right_value > cap.bit_length() + 1:
                sign = -1 if left_value < 0 and right_value % 2 else 1
                return sign * (cap + 1), False
            value = left_value**right_value
        else:
            return None
    except (OverflowError, ZeroDivisionError):
        return None
    return _clamp_integer(value, cap)


def _static_sequence_size(node):
    """Return ``(kind, units)`` for a directly repeated sequence expression."""
    if isinstance(node, _ast.Constant):
        if isinstance(node.value, str):
            return "str", len(node.value.encode("utf-8"))
        if isinstance(node.value, bytes):
            return "bytes", len(node.value)
    if isinstance(node, (_ast.List, _ast.Tuple)):
        return "collection", len(node.elts)
    if (
        isinstance(node, _ast.Call)
        and isinstance(node.func, _ast.Name)
        and node.func.id == "str"
        and len(node.args) <= 1
        and not node.keywords
    ):
        if not node.args:
            return "str", 0
        value_node = node.args[0]
        sequence = _static_sequence_size(value_node)
        if sequence is not None and sequence[0] == "str":
            return sequence
        if isinstance(value_node, _ast.Constant):
            value = value_node.value
        elif (
            isinstance(value_node, _ast.UnaryOp)
            and isinstance(value_node.op, (_ast.UAdd, _ast.USub))
            and isinstance(value_node.operand, _ast.Constant)
            and isinstance(value_node.operand.value, (int, float, complex))
        ):
            value = value_node.operand.value
            value = value if isinstance(value_node.op, _ast.UAdd) else -value
        else:
            return None
        return "str", len(str(value).encode("utf-8"))

    if not isinstance(node, _ast.BinOp):
        return None

    if isinstance(node.op, _ast.Add):
        left = _static_sequence_size(node.left)
        right = _static_sequence_size(node.right)
        if left is None or right is None or left[0] != right[0]:
            return None
        return left[0], left[1] + right[1]
    if not isinstance(node.op, _ast.Mult):
        return None

    sequence = _static_sequence_size(node.left)
    multiplier_node = node.right
    if sequence is None:
        sequence = _static_sequence_size(node.right)
        multiplier_node = node.left
    if sequence is None:
        return None

    kind, units = sequence
    limit = (
        _MAX_STATIC_COLLECTION_ITEMS
        if kind == "collection"
        else _MAX_STATIC_TEXT_BYTES
    )
    multiplier = _static_integer(multiplier_node, limit + 1)
    if multiplier is None:
        return None
    count = max(0, multiplier[0])
    if units and count > limit // units:
        return kind, limit + 1
    return kind, units * count


def _static_range_length(node):
    if not (
        isinstance(node, _ast.Call)
        and isinstance(node.func, _ast.Name)
        and node.func.id == "range"
        and not node.keywords
        and 1 <= len(node.args) <= 3
    ):
        return None

    cap = _MAX_MATERIALIZED_RANGE_ITEMS + 1
    values = [_static_integer(argument, cap) for argument in node.args]
    if any(value is None for value in values):
        return None
    if len(values) == 1 and not values[0][1]:
        return cap if values[0][0] > 0 else 0
    if not all(value[1] for value in values):
        return None
    try:
        return len(range(*(value[0] for value in values)))
    except ValueError:
        return None


def _static_iterable_length(node):
    range_length = _static_range_length(node)
    if range_length is not None:
        return range_length
    if isinstance(node, (_ast.List, _ast.Tuple, _ast.Set)):
        return len(node.elts)
    if not (
        isinstance(node, _ast.Call)
        and isinstance(node.func, _ast.Name)
        and not node.keywords
    ):
        return None
    name = node.func.id
    if name in {"enumerate", "reversed"} and node.args:
        return _static_iterable_length(node.args[0])
    if name in {"map", "filter"} and len(node.args) >= 2:
        return _static_iterable_length(node.args[1])
    if name == "zip" and node.args:
        lengths = [_static_iterable_length(argument) for argument in node.args]
        if all(length is not None for length in lengths):
            return min(lengths)
    return None


def _static_integer_bit_lower_bound(node):
    """Return a lower bound for the bit length without building the integer."""
    if isinstance(node, _ast.Constant) and isinstance(node.value, int):
        return abs(node.value).bit_length()
    if isinstance(node, _ast.UnaryOp) and isinstance(
        node.op, (_ast.UAdd, _ast.USub)
    ):
        return _static_integer_bit_lower_bound(node.operand)
    if not isinstance(node, _ast.BinOp):
        return None

    if isinstance(node.op, _ast.Pow):
        base_bits = _static_integer_bit_lower_bound(node.left)
        exponent = _static_integer(node.right, _MAX_STATIC_INTEGER_BITS + 1)
        if base_bits is None or exponent is None or exponent[0] < 0:
            return None
        if exponent[0] == 0:
            return 1
        if base_bits <= 1:
            return base_bits
        return (base_bits - 1) * exponent[0] + 1

    if isinstance(node.op, _ast.Mult):
        left_bits = _static_integer_bit_lower_bound(node.left)
        right_bits = _static_integer_bit_lower_bound(node.right)
        if left_bits is None or right_bits is None:
            return None
        if left_bits == 0 or right_bits == 0:
            return 0
        return left_bits + right_bits - 1
    return None


def _reject_oversized_integer_power(base_node, exponent_node):
    base_bits = _static_integer_bit_lower_bound(base_node)
    exponent = _static_integer(exponent_node, _MAX_STATIC_INTEGER_BITS + 1)
    if base_bits is None or exponent is None or exponent[0] < 0:
        return
    exponent_value = exponent[0]
    if exponent_value == 0 or base_bits <= 1:
        return

    # (bit_length(base) - 1) * exponent + 1 is a lower bound for the
    # result's bit length.  A lower bound avoids rejecting a near-limit power
    # whose exact result remains within the documented budget.
    lower_bound = (base_bits - 1) * exponent_value + 1
    if lower_bound > _MAX_STATIC_INTEGER_BITS:
        raise _RejectedSource(
            "static integer result exceeds 1000000 bits"
        )


def _validate_static_cost(tree):
    """Reject statically provable, direct resource-exhaustion expressions."""
    node_count = 0
    literal_bytes = 0
    stack = [(tree, 1)]
    while stack:
        node, depth = stack.pop()
        node_count += 1
        if node_count > _MAX_AST_NODES:
            raise _RejectedSource("AST exceeds 20000 nodes")
        if depth > _MAX_AST_DEPTH:
            raise _RejectedSource("AST depth exceeds 100")
        if isinstance(node, _ast.Constant):
            if isinstance(node.value, str):
                literal_bytes += len(node.value.encode("utf-8"))
            elif isinstance(node.value, bytes):
                literal_bytes += len(node.value)
            if literal_bytes > _MAX_LITERAL_BYTES:
                raise _RejectedSource("literal data exceeds 131072 bytes")
        stack.extend((child, depth + 1) for child in _ast.iter_child_nodes(node))

    for node in _ast.walk(tree):
        sequence = _static_sequence_size(node)
        if sequence is not None:
            kind, units = sequence
            if kind in {"str", "bytes"} and units > _MAX_STATIC_TEXT_BYTES:
                raise _RejectedSource(
                    "static text result exceeds 1048576 bytes"
                )
            if kind == "collection" and units > _MAX_STATIC_COLLECTION_ITEMS:
                raise _RejectedSource(
                    "static collection result exceeds 100000 items"
                )

        if isinstance(node, _ast.BinOp) and isinstance(node.op, _ast.Pow):
            _reject_oversized_integer_power(node.left, node.right)
        elif (
            isinstance(node, _ast.Call)
            and isinstance(node.func, _ast.Name)
            and node.func.id == "pow"
            and len(node.args) == 2
            and not node.keywords
        ):
            _reject_oversized_integer_power(node.args[0], node.args[1])

        bytes_integer_argument = False
        if (
            isinstance(node, _ast.Call)
            and isinstance(node.func, _ast.Name)
            and node.func.id == "bytes"
            and len(node.args) == 1
            and not node.keywords
        ):
            count = _static_integer(node.args[0], _MAX_STATIC_TEXT_BYTES + 1)
            if count is not None:
                bytes_integer_argument = True
                if count[0] > _MAX_STATIC_TEXT_BYTES:
                    raise _RejectedSource(
                        "static text result exceeds 1048576 bytes"
                    )

        materialized_node = None
        if (
            isinstance(node, _ast.Call)
            and isinstance(node.func, _ast.Name)
            and node.func.id
            in {"list", "tuple", "set", "frozenset", "sorted", "bytes", "dict"}
            and len(node.args) == 1
            and not node.keywords
            and not (node.func.id == "bytes" and bytes_integer_argument)
        ):
            materialized_node = node.args[0]
        elif isinstance(node, _ast.Starred):
            materialized_node = node.value
        elif (
            isinstance(node, _ast.Call)
            and isinstance(node.func, _ast.Attribute)
            and isinstance(node.func.value, _ast.Name)
            and node.func.value.id == "dict"
            and node.func.attr == "fromkeys"
            and node.args
            and not node.keywords
        ):
            materialized_node = node.args[0]

        if materialized_node is not None:
            length = _static_iterable_length(materialized_node)
            if length is not None and length > _MAX_MATERIALIZED_RANGE_ITEMS:
                raise _RejectedSource(
                    "materialized range exceeds 100000 items"
                )


def _validate_node(node):
    node_type = type(node)
    if node_type not in _ALLOWED_AST_NODES:
        raise _RejectedSource("AST node is not allowlisted: " + node_type.__name__)

    if isinstance(node, (_ast.Name, _ast.Attribute, _ast.arg)):
        if isinstance(node, _ast.Name):
            identifier = node.id
        elif isinstance(node, _ast.Attribute):
            identifier = node.attr
        else:
            identifier = node.arg
        if _is_dunder(identifier):
            raise _RejectedSource("dunder names and attributes are unavailable")
        if identifier in _FORBIDDEN_NAMES:
            raise _RejectedSource("name is unavailable: " + identifier)

    if isinstance(node, _ast.ImportFrom):
        if node.level != 0 or node.module not in _ALLOWED_MODULES:
            raise _RejectedSource("module is not allowlisted: " + repr(node.module))
        for alias in node.names:
            if alias.name == "*":
                raise _RejectedSource("star imports are unavailable")
            if _is_dunder(alias.name) or alias.name in _FORBIDDEN_NAMES:
                raise _RejectedSource("import name is unavailable")
            if alias.asname in _FORBIDDEN_NAMES or (
                alias.asname is not None and _is_dunder(alias.asname)
            ):
                raise _RejectedSource("import name is unavailable")

    if isinstance(node, _ast.Import):
        for alias in node.names:
            if alias.name not in _ALLOWED_MODULES:
                raise _RejectedSource("module is not allowlisted")
            if alias.asname in _FORBIDDEN_NAMES or (
                alias.asname is not None and _is_dunder(alias.asname)
            ):
                raise _RejectedSource("import name is unavailable")

    if isinstance(node, _ast.keyword) and node.arg is None:
        raise _RejectedSource("dynamic keyword expansion is unavailable")
    if isinstance(node, _ast.keyword) and (
        _is_dunder(node.arg) or node.arg in _FORBIDDEN_NAMES
    ):
        raise _RejectedSource("keyword name is unavailable: " + node.arg)

    if isinstance(node, _ast.ExceptHandler) and node.name is not None:
        if _is_dunder(node.name) or node.name in _FORBIDDEN_NAMES:
            raise _RejectedSource("exception binding name is unavailable")

    if isinstance(node, _ast.FunctionDef):
        if node.decorator_list or node.returns is not None:
            raise _RejectedSource("function decorators and annotations are unavailable")

    if isinstance(node, _ast.With):
        raise _RejectedSource("with statements are unavailable")

    if isinstance(node, _ast.Yield):
        raise _RejectedSource("yield is unavailable")

    for child in _ast.iter_child_nodes(node):
        _validate_node(child)


def _validate_source(source):
    if (
        len(source) > _MAX_SOURCE_BYTES
        or len(source.encode("utf-8")) > _MAX_SOURCE_BYTES
    ):
        raise _RejectedSource("source exceeds 262144 UTF-8 bytes")
    try:
        tree = _ast.parse(source, filename="<amber-shell-python>", mode="exec")
    except SyntaxError as error:
        raise _RejectedSource("syntax error: " + str(error)) from None
    _validate_static_cost(tree)
    _validate_node(tree)
    _reject_module_attribute_mutations(tree, _module_bindings(tree))
    return tree


def _result_with_output_limit(exit_code, stdout, stderr):
    if not stdout.truncated and not stderr.truncated:
        return exit_code, stdout.getvalue(), stderr.getvalue()
    if stderr.truncated:
        replacement = _LimitedTextStream(_MAX_OUTPUT_BYTES)
        replacement.write(_OUTPUT_LIMIT_ERROR)
        stderr = replacement
    else:
        stderr.write(_OUTPUT_LIMIT_ERROR)
    return 1, stdout.getvalue(), stderr.getvalue()


def execute(source, stdin):
    """Execute one validated source string and return ``(exit, stdout, stderr)``."""
    if not isinstance(source, str) or not isinstance(stdin, str):
        return 2, "", "AmberShell Python source and stdin must be strings.\n"
    if len(stdin.encode("utf-8")) > _MAX_STDIN_BYTES:
        return 2, "", "AmberShell Python stdin cannot exceed 65536 UTF-8 bytes.\n"

    # A previous job may have left imported modules (or their submodules) in
    # ``sys.modules``.  Clear that state before validation and execution so a
    # failed cleanup on an earlier path cannot become a later job's input.
    _reset_allowlisted_modules()

    stdout = _LimitedTextStream(_MAX_OUTPUT_BYTES)
    stderr = _LimitedTextStream(_MAX_OUTPUT_BYTES)
    old_stdin, old_stdout, old_stderr = _sys.stdin, _sys.stdout, _sys.stderr
    try:
        _sys.stdin = _InputStream(stdin)
        _sys.stdout = stdout
        _sys.stderr = stderr
        try:
            tree = _validate_source(source)
        except _RejectedSource as error:
            stderr.write("AmberShell Python rejected: " + str(error) + "\n")
            return _result_with_output_limit(2, stdout, stderr)

        try:
            code = compile(tree, "<amber-shell-python>", "exec", dont_inherit=True)
            namespace = {
                "__name__": "__amber_shell_user__",
                "__builtins__": _safe_builtins(),
            }
            exec(code, namespace, namespace)
        except BaseException:
            _traceback.print_exc(file=stderr)
            return _result_with_output_limit(1, stdout, stderr)
        return _result_with_output_limit(0, stdout, stderr)
    finally:
        _sys.stdin, _sys.stdout, _sys.stderr = old_stdin, old_stdout, old_stderr
        # Do this on every result path, including rejected source and Python
        # exceptions.  User code never gets to retain an allowlisted module
        # object after the call returns.
        _reset_allowlisted_modules()
