"""AmberShell's deliberately small, non-sandbox Python execution helper.

This module is part of the app bundle. The Objective-C bridge initializes
CPython with an isolated path configuration and calls :func:`execute` for
each foreground command while retaining one interpreter for the process.
"""

import ast as _ast
import builtins as _builtins
import sys as _sys
import traceback as _traceback


_MAX_STDIN_BYTES = 64 * 1024
_MAX_OUTPUT_BYTES = 128 * 1024
_OUTPUT_LIMIT_ERROR = "AmberShell Python output exceeded 131072 UTF-8 bytes.\n"

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


def _safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    if level != 0 or name not in _ALLOWED_MODULES:
        raise ImportError("AmberShell Python import is not allowlisted: " + repr(name))
    fromlist = fromlist or ()
    if any(
        isinstance(item, str) and (item.startswith("__") or item.endswith("__"))
        for item in fromlist
    ):
        raise ImportError("AmberShell Python import name cannot be a dunder.")
    return _ORIGINAL_IMPORT(name, globals, locals, fromlist, level)


_ORIGINAL_IMPORT = _builtins.__import__


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


def _validate_node(node):
    node_type = type(node)
    if node_type not in _ALLOWED_AST_NODES:
        raise _RejectedSource("AST node is not allowlisted: " + node_type.__name__)

    if isinstance(node, (_ast.Name, _ast.Attribute, _ast.arg)):
        identifier = node.id if isinstance(node, (_ast.Name, _ast.arg)) else node.attr
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
    try:
        tree = _ast.parse(source, filename="<amber-shell-python>", mode="exec")
    except SyntaxError as error:
        raise _RejectedSource("syntax error: " + str(error)) from None
    _validate_node(tree)
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
