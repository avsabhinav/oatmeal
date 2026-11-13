import mr
import mr.core


def test_version():
    assert mr.__version__ == "0.1.2"


def test_core_imports():
    assert hasattr(mr.core, "__name__")
