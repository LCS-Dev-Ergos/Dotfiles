"""Ecosystem adapters in bootstrap order; `--only` accepts these names."""

from .haskell import HaskellAdapter
from .julia import JuliaAdapter
from .jvm import JvmAdapter
from .lean import LeanAdapter
from .node import NodeAdapter
from .ocaml import OcamlAdapter
from .python import PythonAdapter
from .ruby import RubyAdapter
from .rust import RustAdapter
from .toolchain import ToolchainAdapter

ADAPTERS = {
    adapter.language: adapter
    for adapter in (
        NodeAdapter,
        PythonAdapter,
        OcamlAdapter,
        RustAdapter,
        HaskellAdapter,
        LeanAdapter,
        RubyAdapter,
        JvmAdapter,
        JuliaAdapter,
    )
}
TOOLCHAINS = {
    language: adapter
    for language, adapter in ADAPTERS.items()
    if issubclass(adapter, ToolchainAdapter)
}
