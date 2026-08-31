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
    try:
        tree = _ast.parse(source, filename="<amber-shell-python>", mode="exec")
    except SyntaxError as error:
        raise _RejectedSource("syntax error: " + str(error)) from None
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
