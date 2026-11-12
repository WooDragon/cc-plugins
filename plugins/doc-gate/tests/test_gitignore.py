"""全库扫描遵守 .gitignore 的行为测试（#299）。

被忽略的内容不得进入链接图谱（docs-graph）或 BM25 语料（recall-gate）。
判定按「最近祖先 git 仓库」分段：外层仓库忽略某个子目录，不等于该目录里的
嵌套仓库也被忽略——Infra monorepo 正是靠这条才没有把三个子仓整片判成不可见。

行为主路径用真实 git 在 tmp_path 造仓库（git init + 提交 + .gitignore），
不做 mock；git 必须存在于 PATH，缺失时整组跳过而不是给出假绿。退化路径
（git 调用失败 / 超时）与归一化键的判定则用 monkeypatch 或直接构造
`GitVisibility` 映射来钉，避免依赖本机文件系统的大小写 / 归一化特性。
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path

import pytest

_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))

# recall-gate.py / docs-graph.py 文件名带连字符，只能按路径加载；
# _doc_gate_common 先进入 sys.path，两个模块的裸 import 才能成立。
def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, _TOOLS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recall_gate = _load("recall_gate", "recall-gate.py")
docs_graph = _load("docs_graph", "docs-graph.py")
import _doc_gate_common as doc_gate_common  # noqa: E402  (与 recall_gate 共用同一模块对象)

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None, reason="git 不可用，无法构造过滤行为测试"
)


@pytest.fixture(autouse=True)
def _isolated_git_env(tmp_path_factory, monkeypatch):
    """隔离用户与系统级 git 配置，避免全局 excludes 影响 --exclude-standard。"""
    home = tmp_path_factory.mktemp("git-home")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home / ".config"))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_AUTHOR_NAME", "doc-gate-test")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "doc-gate-test@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "doc-gate-test")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "doc-gate-test@example.invalid")


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def _init_repo(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    _git(path, "init", "-q")
    return path


def _commit_all(repo: Path) -> None:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "init")


def _write(path: Path, title: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# {title}\n\n正文一句话。\n", encoding="utf-8")
    return path


def _rel(repo: Path, path: Path) -> str:
    return os.path.relpath(str(path.resolve()), str(repo.resolve()))


def _visibility(repo: Path, *relative_keys: str) -> doc_gate_common.GitVisibility:
    """直接构造 GitVisibility 映射，不经过 git，也不依赖文件系统特性。"""
    return doc_gate_common.GitVisibility({
        repo.resolve(): frozenset(
            doc_gate_common._visibility_key(key) for key in relative_keys
        ),
    })


def _corpus_paths(repo: Path):
    corpus, all_files, _forward, _backward, _dangling = recall_gate.build_corpus_and_graph(str(repo))
    return {doc["path"] for doc in corpus}, all_files


def test_ignored_directory_hidden_from_both_scanners(tmp_path):
    """(a) 被忽略目录内的 .md 既不是图节点，也不进语料。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    kept = _write(repo / "docs" / "keep.md", "keep")
    ignored = _write(repo / ".cache" / "mod" / "README.md", "ignored")
    _commit_all(repo)

    graph_files, _outgoing, _forward, _backward = docs_graph.build_graph(repo)
    assert kept.resolve() in graph_files
    assert ignored.resolve() not in graph_files
    assert ignored.resolve() not in docs_graph.scan_all_files(repo)

    corpus_paths, all_files = _corpus_paths(repo)
    assert _rel(repo, ignored) not in all_files
    assert _rel(repo, ignored) not in corpus_paths
    assert _rel(repo, kept) in all_files
    assert _rel(repo, kept) in corpus_paths


def test_untracked_and_tracked_markdown_both_visible(tmp_path):
    """(b) 未跟踪但未被忽略的新文档出现；(c) 已跟踪文档出现。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text("*.log\n", encoding="utf-8")
    tracked = _write(repo / "docs" / "tracked.md", "tracked")
    _commit_all(repo)
    untracked = _write(repo / "docs" / "untracked.md", "untracked")

    files = docs_graph.scan_all_files(repo)
    corpus_paths, all_files = _corpus_paths(repo)
    for path in (tracked, untracked):
        assert path.resolve() in files
        assert _rel(repo, path) in all_files
        assert _rel(repo, path) in corpus_paths


def test_nested_repository_uses_its_own_gitignore(tmp_path):
    """(d) 外层忽略 sub/ 不影响 sub 自身仓库的可见性。

    Infra monorepo 的回归点：根 .gitignore 排出三个子仓目录，若只对 root 调一次
    git ls-files，子仓全部文档都会消失、链接全变断链。
    """
    outer = _init_repo(tmp_path / "outer")
    (outer / ".gitignore").write_text("sub/\n", encoding="utf-8")
    outer_doc = _write(outer / "docs" / "outer.md", "outer")
    _commit_all(outer)

    sub = _init_repo(outer / "sub")
    (sub / ".gitignore").write_text("secret/\n", encoding="utf-8")
    inside = _write(sub / "docs" / "a.md", "inner doc")
    ignored = _write(sub / "secret" / "hidden.md", "inner secret")
    _commit_all(sub)

    files = docs_graph.scan_all_files(outer)
    assert inside.resolve() in files
    assert outer_doc.resolve() in files
    assert ignored.resolve() not in files

    corpus_paths, all_files = _corpus_paths(outer)
    assert _rel(outer, inside) in all_files
    assert _rel(outer, inside) in corpus_paths
    assert _rel(outer, ignored) not in all_files
    assert _rel(outer, ignored) not in corpus_paths


def test_non_git_directory_keeps_all_markdown(tmp_path):
    """(e) 退化路径：root 下没有仓库根时保持历史行为，全部保留。"""
    plain = tmp_path / "plain"
    a = _write(plain / "docs" / "a.md", "a")
    b = _write(plain / "vendor" / "b.md", "b")

    assert docs_graph.scan_all_files(plain) == {a.resolve(), b.resolve()}

    corpus_paths, all_files = _corpus_paths(plain)
    assert all_files == {_rel(plain, a), _rel(plain, b)}
    assert corpus_paths == all_files


def test_git_info_exclude_is_respected(tmp_path):
    """(f) .git/info/exclude 命中的文件不出现。"""
    repo = _init_repo(tmp_path / "repo")
    info_dir = repo / ".git" / "info"
    info_dir.mkdir(parents=True, exist_ok=True)
    (info_dir / "exclude").write_text("excluded-by-info.md\n", encoding="utf-8")
    hidden = _write(repo / "docs" / "excluded-by-info.md", "hidden")
    kept = _write(repo / "docs" / "kept.md", "kept")
    _commit_all(repo)

    files = docs_graph.scan_all_files(repo)
    assert hidden.resolve() not in files
    assert kept.resolve() in files

    corpus_paths, all_files = _corpus_paths(repo)
    assert _rel(repo, hidden) not in all_files
    assert _rel(repo, hidden) not in corpus_paths
    assert _rel(repo, kept) in corpus_paths


def test_path_outside_any_repo_is_kept(tmp_path):
    """退化路径：root 非 git 但含嵌套仓库时，仓库外的文件仍然保留。"""
    workspace = tmp_path / "workspace"
    loose = _write(workspace / "notes" / "loose.md", "loose")
    inner = _init_repo(workspace / "sub")
    (inner / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    hidden = _write(inner / ".cache" / "x.md", "hidden")
    visible = _write(inner / "docs" / "y.md", "visible")
    _commit_all(inner)

    files = docs_graph.scan_all_files(workspace)
    assert loose.resolve() in files
    assert visible.resolve() in files
    assert hidden.resolve() not in files

    corpus_paths, all_files = _corpus_paths(workspace)
    assert _rel(workspace, loose) in all_files
    assert _rel(workspace, loose) in corpus_paths
    assert _rel(workspace, visible) in corpus_paths
    assert _rel(workspace, hidden) not in all_files
    assert _rel(workspace, hidden) not in corpus_paths


def test_git_failure_fails_open(tmp_path, monkeypatch):
    """退化路径：某仓库 git 查询失败时该仓库范围内不启用过滤，绝不误删文档。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    ignored = _write(repo / ".cache" / "README.md", "ignored")
    _commit_all(repo)

    def _failing_run(*args, **kwargs):
        return subprocess.CompletedProcess(args=args, returncode=1, stdout=b"", stderr=b"boom")

    monkeypatch.setattr(doc_gate_common.subprocess, "run", _failing_run)

    files = docs_graph.scan_all_files(repo)
    assert ignored.resolve() in files

    corpus_paths, all_files = _corpus_paths(repo)
    assert _rel(repo, ignored) in all_files
    assert _rel(repo, ignored) in corpus_paths


def test_git_unavailable_fails_open(tmp_path, monkeypatch):
    """git 不存在（OSError）时该仓库范围 fail-open，不丢已跟踪文档。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    ignored = _write(repo / ".cache" / "README.md", "ignored")
    _commit_all(repo)

    def _missing_git(*args, **kwargs):
        raise FileNotFoundError(2, "git", "not found")

    monkeypatch.setattr(doc_gate_common.subprocess, "run", _missing_git)

    assert doc_gate_common.build_git_visibility(repo).is_visible(ignored)
    corpus_paths, all_files = _corpus_paths(repo)
    assert _rel(repo, ignored) in all_files
    assert _rel(repo, ignored) in corpus_paths


def test_git_timeout_fails_open(tmp_path, monkeypatch):
    """git 挂起（超时）按查询失败处理：该仓库范围 fail-open。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    ignored = _write(repo / ".cache" / "README.md", "ignored")
    _commit_all(repo)

    seen_kwargs = {}

    def _timed_out(*args, **kwargs):
        seen_kwargs.update(kwargs)
        raise subprocess.TimeoutExpired(cmd="git ls-files", timeout=kwargs.get("timeout", 0))

    monkeypatch.setattr(doc_gate_common.subprocess, "run", _timed_out)

    assert doc_gate_common.build_git_visibility(repo).is_visible(ignored)
    # 钉住生产代码确实传了 timeout：假 run 不传也会抛，只有这条断言能杀掉
    # 「删掉 timeout= 参数」的变异。
    assert seen_kwargs.get("timeout") == doc_gate_common._GIT_LS_FILES_TIMEOUT_SEC


def test_tracked_uppercase_markdown_visible_through_real_git(tmp_path):
    """真实 git 产出侧的归一化：索引路径必须经 `_visibility_key` 再比较。

    若 `_repo_visible_files` 把 `visible.add(_visibility_key(relative))` 改回
    `visible.add(relative)`，集合里是 casefold 值而查询键已 casefold → 不匹配，
    这条在任何平台都会变红。它守的正是 macOS 上 CLAUDE.md / README.md 这类
    含大写字母的已跟踪文档不会从图谱与语料里静默消失。
    """
    repo = _init_repo(tmp_path / "repo")
    guide = _write(repo / "docs" / "Guide.md", "guide")
    readme = _write(repo / "README.md", "readme")
    _commit_all(repo)

    graph_files, _outgoing, _forward, _backward = docs_graph.build_graph(repo)
    assert guide.resolve() in graph_files
    assert readme.resolve() in graph_files

    corpus_paths, all_files = _corpus_paths(repo)
    for path in (guide, readme):
        assert _rel(repo, path) in all_files
        assert _rel(repo, path) in corpus_paths


def test_tracked_unicode_markdown_visible_through_real_git(tmp_path):
    """真实 git 产出侧的 Unicode 路径：NFC/NFD 都能端到端进入图谱与语料。

    macOS 上 APFS 可能把磁盘写法归一化为与索引不同的组合形式；统一 NFC 键
    后两边仍匹配。Linux 上两侧本就一致，这条退化为恒真但无害。
    """
    repo = _init_repo(tmp_path / "repo")
    nfc_name = unicodedata.normalize("NFC", "café.md")
    doc = _write(repo / "docs" / nfc_name, "cafe")
    _commit_all(repo)

    graph_files, _outgoing, _forward, _backward = docs_graph.build_graph(repo)
    assert doc.resolve() in graph_files

    corpus_paths, all_files = _corpus_paths(repo)
    assert _rel(repo, doc) in all_files
    assert _rel(repo, doc) in corpus_paths


def test_linked_worktree_git_file_is_discovered(tmp_path):
    """`.git` 是文件（linked worktree）时仓库仍被发现并参与过滤。"""
    repo = _init_repo(tmp_path / "repo")
    (repo / ".gitignore").write_text(".cache/\n", encoding="utf-8")
    _write(repo / "docs" / "a.md", "a")
    _commit_all(repo)

    worktree = tmp_path / "wt"
    _git(repo, "worktree", "add", "-q", "--detach", str(worktree), "HEAD")
    assert (worktree / ".git").is_file()

    hidden = _write(worktree / ".cache" / "x.md", "hidden")
    files = docs_graph.scan_all_files(worktree)
    assert (worktree / "docs" / "a.md").resolve() in files
    assert hidden.resolve() not in files


def test_visibility_key_ignores_case_difference(tmp_path):
    """索引写 Guide.md、磁盘读到 guide.md（未用 git mv 的改名）→ 仍可见。"""
    repo = tmp_path / "repo"
    repo.mkdir()
    visibility = _visibility(repo, "docs/Guide.md")

    assert visibility.is_visible(repo / "docs" / "guide.md")
    assert visibility.is_visible(repo / "docs" / "GUIDE.MD")


def test_visibility_key_ignores_unicode_normalization_difference(tmp_path):
    """索引是 NFC、磁盘返回 NFD（APFS 可能如此）→ 仍可见。"""
    repo = tmp_path / "repo"
    repo.mkdir()
    nfc = unicodedata.normalize("NFC", "docs/café.md")
    nfd = unicodedata.normalize("NFD", "docs/café.md")
    assert nfc != nfd

    visibility = _visibility(repo, nfc)

    assert visibility.is_visible(repo / nfd)


def test_visibility_key_negative_control(tmp_path):
    """真的不在集合里的路径必须仍然不可见，否则上面的放行没有意义。"""
    repo = tmp_path / "repo"
    repo.mkdir()
    visibility = _visibility(repo, "docs/tracked.md")

    assert not visibility.is_visible(repo / "docs" / "untracked.md")
    assert not visibility.is_visible(repo / "other" / "tracked.md")
    assert not visibility.is_visible(repo / "docs" / "tracked.md.bak")
