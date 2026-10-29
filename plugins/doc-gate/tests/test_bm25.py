"""Behavior and compatibility tests for doc-gate's sparse BM25 scorer."""

import copy
import importlib.util
import json
import math
import random
import subprocess
import sys
from collections import Counter as StdCounter
from pathlib import Path

import pytest

_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))
_spec = importlib.util.spec_from_file_location("recall_gate", _TOOLS_DIR / "recall-gate.py")
recall_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recall_gate)


def _doc(path, tokens, title_tokens=()):
    return {
        "path": path,
        "title": path.rsplit(".", 1)[0],
        "tokens": list(tokens),
        "title_tokens": list(title_tokens),
        "token_count": len(tokens),
    }


def _counter_score(query_tokens, doc_tokens, doc_len, avg_dl, idf, k1=1.2, b=0.75):
    """Independent Counter-weighted oracle for the current BM25 arithmetic."""
    frequencies = StdCounter(doc_tokens)
    score = 0.0
    denominator_base = 1.0 - b + b * (doc_len / avg_dl) if avg_dl > 0 else 1.0
    for term, query_frequency in StdCounter(query_tokens).items():
        term_frequency = frequencies.get(term, 0)
        if term_frequency and term in idf:
            numerator = term_frequency * (k1 + 1)
            denominator = term_frequency + k1 * denominator_base
            score += query_frequency * idf[term] * (numerator / denominator if denominator > 0 else 0.0)
    return score


def _legacy_score(query_tokens, doc_tokens, doc_len, avg_dl, idf, k1=1.2, b=0.75):
    """Frozen earlier token-by-token oracle retained for historical compatibility."""
    frequencies = StdCounter(doc_tokens)
    score = 0.0
    denominator_base = 1.0 - b + b * (doc_len / avg_dl) if avg_dl > 0 else 1.0
    for term in query_tokens:
        if term not in idf:
            continue
        term_frequency = frequencies.get(term, 0)
        numerator = term_frequency * (k1 + 1)
        denominator = term_frequency + k1 * denominator_base
        score += idf[term] * (numerator / denominator if denominator > 0 else 0.0)
    return score


def _legacy_indexes(corpus):
    content_tokens = [doc["tokens"] for doc in corpus]
    title_tokens = [doc["title_tokens"] for doc in corpus]
    document_count = len(corpus)
    avg_dl = sum(doc["token_count"] for doc in corpus) / document_count if document_count else 1.0
    avg_title_dl = sum(len(tokens) for tokens in title_tokens) / document_count if document_count else 1.0
    return (
        recall_gate.build_idf(content_tokens),
        recall_gate.build_idf(title_tokens),
        avg_dl,
        avg_title_dl,
    )


def _legacy_rank(query_text, query_filename, corpus, threshold=0.0, top_n=10):
    """Counter-weighted ranking oracle preserving public ranking behavior."""
    content_idf, title_idf, avg_dl, avg_title_dl = _legacy_indexes(corpus)
    query_tokens = recall_gate.tokenize(query_text)
    query_basename = Path(query_filename).name
    content_scores = [
        (index, _counter_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf))
        for index, doc in enumerate(corpus)
    ]
    content_scores.sort(key=lambda item: item[1], reverse=True)
    max_content = max((score for _, score in content_scores), default=0.0)
    title_scores = [
        _counter_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
        for doc in corpus
    ]
    max_title = max(title_scores, default=0.0)

    ranked = []
    for index, content_score in content_scores:
        doc = corpus[index]
        if Path(doc["path"]).name in recall_gate.ORPHAN_WHITELIST:
            continue
        if Path(doc["path"]).as_posix() == Path(query_filename).as_posix():
            continue
        content_normalized = content_score / max_content if max_content > 0 else 0.0
        title_normalized = title_scores[index] / max_title if max_title > 0 else 0.0
        filename_score = recall_gate.filename_jaccard(query_basename, doc["path"])
        combined = (
            0.65 * content_normalized + 0.25 * filename_score + 0.10 * title_normalized
            if query_basename
            else 0.75 * content_normalized + 0.25 * title_normalized
        )
        if combined >= threshold:
            ranked.append({"path": doc["path"], "score": round(combined, 4), "title": doc["title"]})
    ranked.sort(key=lambda item: item["score"], reverse=True)
    return ranked[:top_n]


def _indexes(corpus):
    return recall_gate.build_indexes(corpus)


def _rank(query_text, query_filename, corpus, threshold=0.0, top_n=10):
    content_index, title_index = _indexes(corpus)
    return recall_gate.rank_candidates(
        query_text, query_filename, corpus, content_index, title_index, threshold, top_n,
    )


def test_build_indexes_does_not_cache_counters_in_caller_corpus():
    """Given reusable corpus tokens, indexing must not mutate caller-owned docs."""
    corpus = [_doc("one.md", ["alpha", "beta", "alpha"], ["alpha"]), _doc("two.md", ["beta"], [])]
    before_indexing = copy.deepcopy(corpus)

    _indexes(corpus)

    assert corpus == before_indexing
    assert all("term_frequencies" not in " ".join(doc) for doc in corpus)


def test_index_scores_raw_floats_exactly_like_counter_weighted_oracle():
    corpus = [
        _doc("mixed.md", ["alpha", "alpha", "中文", "文档"], ["alpha", "标题"]),
        _doc("other.md", ["beta", "中文", "资料"], ["beta"]),
        _doc("zero.md", [], []),
    ]
    content_index, title_index = _indexes(corpus)
    content_idf, title_idf, avg_dl, avg_title_dl = _legacy_indexes(corpus)
    query_tokens = ["alpha", "alpha", "中文", "unknown"]

    expected_content = [
        _counter_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf)
        for doc in corpus
    ]
    expected_title = [
        _counter_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
        for doc in corpus
    ]

    assert content_index.score(StdCounter(query_tokens)) == expected_content
    assert title_index.score(StdCounter(query_tokens)) == expected_title


class _DivisionCountingLength:
    def __init__(self, value):
        self.value = value
        self.division_count = 0

    def __truediv__(self, denominator):
        self.division_count += 1
        return self.value / denominator


def test_index_normalizes_each_document_once_before_term_iteration():
    lengths = [_DivisionCountingLength(2), _DivisionCountingLength(3)]
    tokens = [["alpha", "beta"], ["gamma", "delta"]]
    idf = {term: 1.0 for term in ("alpha", "beta", "gamma", "delta")}

    recall_gate._build_bm25_index(tokens, lengths, idf, avg_dl=2.5)

    assert [length.division_count for length in lengths] == [1, 1]


def test_scalar_normalizes_once_for_multiple_matching_query_terms_and_skips_zero_average():
    length = _DivisionCountingLength(2)
    query = StdCounter(["alpha", "beta", "alpha", "beta"])
    document = StdCounter(["alpha", "beta"])
    idf = {"alpha": 1.0, "beta": 1.0}

    actual = recall_gate.bm25_score(query, document, length, 2.0, idf)

    assert length.division_count == 1
    assert actual == _counter_score(query, document, 2, 2.0, idf)

    zero_average_length = _DivisionCountingLength(7)
    zero_average_index = recall_gate._build_bm25_index(
        [["alpha", "beta"]], [zero_average_length], idf, avg_dl=0.0,
    )
    zero_average_score = zero_average_index.score(query)[0]

    assert zero_average_length.division_count == 0
    assert zero_average_score == _counter_score(
        query, ["alpha", "beta"], 7, 0.0, idf,
    )


@pytest.mark.parametrize(
    "query,document,doc_len,avg_dl,idf,k1,b",
    [
        (["alpha", "alpha", "beta"], ["alpha", "alpha", "beta"], 3, 3.0, {"alpha": 1.2, "beta": 0.7}, 1.2, 0.75),
        (["missing"], ["alpha"], 1, 0.0, {"alpha": 1.0}, 0.0, 1.0),
        ([], [], 0, 0.0, {}, 1.2, 0.75),
    ],
)
def test_bm25_score_keeps_list_and_counter_compatibility(query, document, doc_len, avg_dl, idf, k1, b):
    legacy_expected = _legacy_score(query, document, doc_len, avg_dl, idf, k1, b)
    counter_expected = _counter_score(query, document, doc_len, avg_dl, idf, k1, b)
    assert legacy_expected == pytest.approx(counter_expected, rel=0, abs=1e-12)

    list_score = recall_gate.bm25_score(query, document, doc_len, avg_dl, idf, k1, b)
    counter_score = recall_gate.bm25_score(
        StdCounter(query), StdCounter(document), doc_len, avg_dl, idf, k1, b,
    )
    assert list_score == pytest.approx(legacy_expected, rel=0, abs=1e-12)
    assert counter_score == pytest.approx(legacy_expected, rel=0, abs=1e-12)
    assert list_score == counter_expected
    assert counter_score == counter_expected


@pytest.mark.parametrize(
    "avg_dl,k1,b,expected",
    [(0.0, 1.2, 0.75, 11 / 8), (2.0, 2.0, 0.75, 3 / 2), (4.0, 1.2, 0.0, 11 / 8), (4.0, 2.0, 1.0, 2.0), (4.0, 0.0, 1.0, 1.0)],
)
def test_bm25_hit_boundaries_have_hand_calculated_results(avg_dl, k1, b, expected):
    list_score = recall_gate.bm25_score(
        ["alpha"], ["alpha", "alpha"], 2, avg_dl, {"alpha": 1.0}, k1, b,
    )
    counter_score = recall_gate.bm25_score(
        StdCounter(["alpha"]), StdCounter(["alpha", "alpha"]), 2,
        avg_dl, {"alpha": 1.0}, k1, b,
    )
    assert list_score == pytest.approx(expected, rel=1e-12, abs=1e-12)
    assert counter_score == pytest.approx(expected, rel=1e-12, abs=1e-12)


def test_batch_bm25_uses_sparse_index_for_body_only_legacy_documents_without_mutation():
    corpus = [
        {"tokens": ["alpha", "beta", "alpha"], "token_count": 3},
        {"tokens": ["beta", "gamma"], "token_count": 2},
        {"tokens": ["gamma"], "token_count": 1},
    ]
    before = copy.deepcopy(corpus)
    query_tokens = ["alpha", "beta", "alpha"]
    idf = {"alpha": 1.2, "beta": 0.7, "gamma": 0.4}
    expected = sorted(
        [(index, _counter_score(query_tokens, doc["tokens"], doc["token_count"], 2.0, idf)) for index, doc in enumerate(corpus)],
        key=lambda item: item[1], reverse=True,
    )

    assert recall_gate.batch_bm25(query_tokens, corpus, idf, 2.0) == expected
    assert corpus == before


def test_batch_bm25_preserves_complete_equal_score_order_and_zero_tail():
    corpus = [
        {"tokens": ["beta"], "token_count": 1},
        {"tokens": ["alpha"], "token_count": 1},
        {"tokens": ["alpha"], "token_count": 1},
    ]
    before = copy.deepcopy(corpus)

    actual = recall_gate.batch_bm25(
        ["alpha", "alpha"], corpus, {"alpha": 1.0, "beta": 1.0}, 1.0,
    )

    assert [index for index, _score in actual] == [1, 2, 0]
    assert actual[0][1] == actual[1][1]
    assert actual[2][1] == 0.0
    assert corpus == before


def test_score_visits_only_postings_for_query_terms_and_preserves_counter_order():
    corpus = [_doc("one.md", ["alpha", "beta"]), _doc("two.md", ["beta"])]
    content_index, _title_index = _indexes(corpus)
    original_postings = content_index.postings
    accesses = []

    class TrackingPostings(dict):
        def get(self, term, default=None):
            accesses.append(term)
            if term == "unknown":
                return ()
            return super().get(term, default)

    content_index.postings = TrackingPostings(original_postings)
    scores = content_index.score(StdCounter(["beta", "unknown", "alpha", "beta"]))

    assert accesses == ["beta", "unknown", "alpha"]
    assert scores == [
        _counter_score(["beta", "unknown", "alpha", "beta"], corpus[0]["tokens"], 2, 1.5, recall_gate.build_idf([doc["tokens"] for doc in corpus])),
        _counter_score(["beta", "unknown", "alpha", "beta"], corpus[1]["tokens"], 1, 1.5, recall_gate.build_idf([doc["tokens"] for doc in corpus])),
    ]


def test_rank_does_not_recompute_document_contributions_after_index_build(monkeypatch):
    corpus = [_doc("one.md", ["alpha", "beta", "alpha"], ["alpha"]), _doc("two.md", ["beta", "gamma"], ["gamma"])]
    content_index, title_index = _indexes(corpus)

    def unexpected_recomputation(*_args, **_kwargs):
        raise AssertionError("rank recomputed a document contribution")

    monkeypatch.setattr(recall_gate, "_bm25_term_contribution", unexpected_recomputation)
    actual = recall_gate.rank_candidates("alpha beta", "query.md", corpus, content_index, title_index)

    assert [item["path"] for item in actual] == ["one.md", "two.md"]


def test_each_rank_builds_only_its_query_counter_after_indexing(monkeypatch):
    corpus = [_doc("one.md", ["alpha", "beta"]), _doc("two.md", ["beta", "gamma"])]
    content_index, title_index = _indexes(corpus)
    counter_calls = []

    def tracking_counter(values=()):
        counter_calls.append(tuple(values))
        return StdCounter(values)

    monkeypatch.setattr(recall_gate, "Counter", tracking_counter)
    recall_gate.rank_candidates("alpha beta", "query.md", corpus, content_index, title_index)
    recall_gate.rank_candidates("beta gamma", "query.md", corpus, content_index, title_index)

    assert counter_calls == [("alpha", "beta"), ("beta", "gamma")]


def test_rank_handles_empty_corpus_empty_query_empty_titles_and_all_zero_scores():
    empty_content, empty_title = _indexes([])
    assert recall_gate.rank_candidates("alpha", "query.md", [], empty_content, empty_title) == []

    corpus = [_doc("one.md", ["alpha"], []), _doc("two.md", ["beta"], [])]
    assert _rank("", "query.md", corpus) == _legacy_rank("", "query.md", corpus)
    assert _rank("unknown", "query.md", corpus) == _legacy_rank("unknown", "query.md", corpus)


def test_rank_empty_query_filename_uses_counter_oracle_and_body_title_weights():
    corpus = [
        _doc("body.md", ["alpha", "alpha", "alpha", "beta"], ["title"]),
        _doc("title.md", ["beta"], ["alpha", "alpha", "alpha"]),
        _doc("mixed.md", ["alpha", "beta"], ["alpha", "beta"]),
    ]

    actual = _rank("alpha alpha beta", "", corpus)

    assert actual == _legacy_rank("alpha alpha beta", "", corpus)

    content_idf, title_idf, avg_dl, avg_title_dl = _legacy_indexes(corpus)
    query_tokens = recall_gate.tokenize("alpha alpha beta")
    body_scores = [
        _counter_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf)
        for doc in corpus
    ]
    title_scores = [
        _counter_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
        for doc in corpus
    ]
    max_body = max(body_scores)
    max_title = max(title_scores)
    expected_by_path = {
        doc["path"]: round(
            0.75 * body_scores[index] / max_body + 0.25 * title_scores[index] / max_title,
            4,
        )
        for index, doc in enumerate(corpus)
    }
    actual_by_path = {item["path"]: item["score"] for item in actual}
    assert actual_by_path == expected_by_path
    body_expected = expected_by_path["body.md"]
    body_wrong_filename_weight = round(
        0.65 * body_scores[0] / max_body + 0.25 * title_scores[0] / max_title,
        4,
    )
    assert body_expected != body_wrong_filename_weight


def test_rank_keeps_self_in_unique_body_and_title_maxima_before_filtering():
    corpus = [
        _doc("query.md", ["alpha"] * 6, ["alpha"] * 6),
        _doc("candidate.md", ["alpha"], ["alpha"]),
        _doc("other.md", ["beta"], ["beta"]),
    ]
    content_idf, title_idf, avg_dl, avg_title_dl = _legacy_indexes(corpus)
    query_tokens = ["alpha"]
    body_scores = [
        _counter_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf)
        for doc in corpus
    ]
    title_scores = [
        _counter_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
        for doc in corpus
    ]

    assert body_scores[0] > max(body_scores[1:])
    assert title_scores[0] > max(title_scores[1:])

    actual = _rank("alpha", "query.md", corpus)

    assert actual == _legacy_rank("alpha", "query.md", corpus)
    assert all(item["path"] != "query.md" for item in actual)


def test_rank_keeps_zero_bm25_documents_for_filename_only_matches():
    corpus = [_doc("alpha-reference.md", ["unrelated"]), _doc("other.md", ["different"])]

    actual = _rank("unknown", "alpha-note.md", corpus)

    assert actual == _legacy_rank("unknown", "alpha-note.md", corpus)
    assert actual[0]["path"] == "alpha-reference.md"
    assert actual[0]["score"] > 0.0


def test_rank_keeps_whitelist_and_self_in_normalization_but_not_results():
    corpus = [
        _doc("README.md", ["alpha"] * 6, ["alpha"] * 3),
        _doc("query.md", ["alpha"] * 5, ["alpha"] * 2),
        _doc("candidate.md", ["alpha"], ["alpha"]),
        _doc("other.md", ["beta"], ["beta"]),
    ]

    actual = _rank("alpha", "query.md", corpus)

    assert actual == _legacy_rank("alpha", "query.md", corpus)
    assert [item["path"] for item in actual] == ["candidate.md", "other.md"]


def test_rank_preserves_raw_order_rounding_threshold_and_top_n_boundaries():
    corpus = [_doc("low.md", ["alpha"] + ["filler"] * 10000), _doc("high.md", ["alpha"] + ["filler"] * 9999)]
    content_idf, _title_idf, avg_dl, _avg_title_dl = _legacy_indexes(corpus)
    raw_scores = [_counter_score(["alpha"], doc["tokens"], doc["token_count"], avg_dl, content_idf) for doc in corpus]
    low_combined = 0.65 * raw_scores[0] / max(raw_scores)

    baseline = _rank("alpha", "query.md", corpus, top_n=2)
    assert baseline == _legacy_rank("alpha", "query.md", corpus, top_n=2)
    assert [item["path"] for item in baseline] == ["high.md", "low.md"]
    assert [item["score"] for item in baseline] == [0.65, 0.65]
    assert _rank("alpha", "query.md", corpus, top_n=1) == [baseline[0]]

    for threshold in (math.nextafter(low_combined, -math.inf), low_combined, math.nextafter(low_combined, math.inf)):
        actual = _rank("alpha", "query.md", corpus, threshold=threshold, top_n=2)
        assert actual == _legacy_rank("alpha", "query.md", corpus, threshold=threshold, top_n=2)


def test_rank_matches_counter_weighted_oracle_for_seeded_random_boundaries():
    randomizer = random.Random(20260908)
    vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon", "中文"]
    corpus = [
        _doc(
            f"candidate-{index}.md",
            [randomizer.choice(vocabulary) for _ in range(randomizer.randint(0, 9))],
            [randomizer.choice(vocabulary) for _ in range(randomizer.randint(0, 3))],
        )
        for index in range(8)
    ]

    for query in ("alpha alpha gamma", "unknown beta", "", "中文 alpha 中文"):
        assert _rank(query, "query-file.md", corpus, threshold=0.15, top_n=4) == _legacy_rank(
            query, "query-file.md", corpus, threshold=0.15, top_n=4,
        )


def test_cli_gate_returns_nonempty_recall_from_real_subprocess(tmp_path):
    (tmp_path / "topic.md").write_text("# Topic\n\nalpha alpha beta shared context\n", encoding="utf-8")
    (tmp_path / "other.md").write_text("# Other\n\nplaceholder\n", encoding="utf-8")

    completed = subprocess.run(
        [sys.executable, str(_TOOLS_DIR / "recall-gate.py"), "--root", str(tmp_path), "--target-file", "other.md", "--threshold", "0.1", "gate"],
        input="# Other\n\nalpha alpha beta shared context\n",
        text=True,
        capture_output=True,
        check=True,
    )
    result = json.loads(completed.stdout)

    assert result["recall"]
    assert result["recall"][0]["path"] == "topic.md"
