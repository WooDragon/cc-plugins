"""Behavior and compatibility tests for doc-gate's BM25 scorer."""

import importlib.util
import math
import random
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


def _legacy_score(query_tokens, doc_tokens, doc_len, avg_dl, idf, k1=1.2, b=0.75):
    """Frozen pre-optimization BM25 oracle for mathematical compatibility."""
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


def _legacy_rank(query_text, query_filename, corpus, content_idf, title_idf, avg_dl, avg_title_dl,
                 threshold=0.0, top_n=10):
    """Frozen external-result oracle preserving the legacy ranking pipeline."""
    query_tokens = recall_gate.tokenize(query_text)
    query_basename = Path(query_filename).name
    content_scores = [
        (index, _legacy_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf))
        for index, doc in enumerate(corpus)
    ]
    content_scores.sort(key=lambda item: item[1], reverse=True)
    max_content = max((score for _, score in content_scores), default=0.0)
    title_scores = [
        _legacy_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
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


def test_rank_prepares_document_counters_once_and_reuses_them(monkeypatch):
    corpus = [
        _doc("one.md", ["alpha", "beta", "alpha"], ["alpha"]),
        _doc("two.md", ["beta", "gamma"], ["gamma"]),
    ]
    counter_calls = []

    def tracking_counter(values=()):
        counter_calls.append(id(values))
        return StdCounter(values)

    monkeypatch.setattr(recall_gate, "Counter", tracking_counter)
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    recall_gate.rank_candidates("alpha beta", "query.md", corpus, content_idf, title_idf, avg_dl, avg_title_dl)
    content_frequency_ids = [id(doc["content_term_frequencies"]) for doc in corpus]
    title_frequency_ids = [id(doc["title_term_frequencies"]) for doc in corpus]
    content_frequency_values = [doc["content_term_frequencies"].copy() for doc in corpus]
    title_frequency_values = [doc["title_term_frequencies"].copy() for doc in corpus]
    recall_gate.rank_candidates("beta gamma", "query.md", corpus, content_idf, title_idf, avg_dl, avg_title_dl)

    # Two corpus documents need content and title frequencies once each; each
    # rank call may build exactly one query Counter, but no document Counter.
    assert len(counter_calls) == 6
    assert all(isinstance(doc["tokens"], list) for doc in corpus)
    assert all(isinstance(doc["title_tokens"], list) for doc in corpus)
    assert [id(doc["content_term_frequencies"]) for doc in corpus] == content_frequency_ids
    assert [id(doc["title_term_frequencies"]) for doc in corpus] == title_frequency_ids
    assert [doc["content_term_frequencies"] for doc in corpus] == content_frequency_values
    assert [doc["title_term_frequencies"] for doc in corpus] == title_frequency_values


@pytest.mark.parametrize(
    "query,document,doc_len,avg_dl,idf,k1,b",
    [
        (["alpha", "alpha", "beta"], ["alpha", "alpha", "beta"], 3, 3.0, {"alpha": 1.2, "beta": 0.7}, 1.2, 0.75),
        (["missing"], ["alpha"], 1, 0.0, {"alpha": 1.0}, 0.0, 1.0),
        ([], [], 0, 0.0, {}, 1.2, 0.75),
    ],
)
def test_bm25_score_keeps_legacy_list_api_and_formula(query, document, doc_len, avg_dl, idf, k1, b):
    expected = _legacy_score(query, document, doc_len, avg_dl, idf, k1, b)
    actual = recall_gate.bm25_score(query, document, doc_len, avg_dl, idf, k1, b)
    assert actual == pytest.approx(expected, abs=1e-12)


@pytest.mark.parametrize(
    "avg_dl,k1,b,expected",
    [
        (0.0, 1.2, 0.75, 11 / 8),
        (2.0, 2.0, 0.75, 3 / 2),
        (4.0, 1.2, 0.0, 11 / 8),
        (4.0, 2.0, 1.0, 2.0),
        (4.0, 0.0, 1.0, 1.0),
    ],
)
def test_bm25_hit_boundaries_have_hand_calculated_results(avg_dl, k1, b, expected):
    query = ["alpha"]
    document = ["alpha", "alpha"]
    doc_len = 2
    idf = {"alpha": 1.0}

    # term_frequency=2 and IDF=1. denominator_base is 1 for the zero-length
    # fallback, avg_dl=doc_len, and b=0; it is 0.5 for avg_dl=4,b=1.
    # The hand-calculated expected values are 11/8, 3/2, 11/8, 2, and 1.
    public_score = recall_gate.bm25_score(query, document, doc_len, avg_dl, idf, k1, b)
    frequency_score = recall_gate._bm25_score_from_frequencies(
        StdCounter(query), StdCounter(document), doc_len, avg_dl, idf, k1, b,
    )
    legacy_score = _legacy_score(query, document, doc_len, avg_dl, idf, k1, b)

    assert public_score == pytest.approx(expected, rel=1e-12, abs=1e-12)
    assert frequency_score == pytest.approx(expected, rel=1e-12, abs=1e-12)
    assert legacy_score == pytest.approx(expected, rel=1e-12, abs=1e-12)


def test_batch_bm25_accepts_body_only_legacy_documents():
    corpus = [
        {"tokens": ["alpha", "beta", "alpha"], "token_count": 3},
        {"tokens": ["beta", "gamma"], "token_count": 2},
        {"tokens": ["gamma"], "token_count": 1},
    ]
    query_tokens = ["alpha", "beta", "alpha"]
    idf = {"alpha": 1.2, "beta": 0.7, "gamma": 0.4}
    avg_dl = 2.0
    expected = [
        (
            index,
            _legacy_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, idf),
        )
        for index, doc in enumerate(corpus)
    ]
    expected.sort(key=lambda item: item[1], reverse=True)

    first = recall_gate.batch_bm25(query_tokens, corpus, idf, avg_dl)
    second = recall_gate.batch_bm25(query_tokens, corpus, idf, avg_dl)

    assert first == second
    for actual in (first, second):
        assert [index for index, _score in actual] == [index for index, _score in expected]
        for (_actual_index, actual_score), (_expected_index, expected_score) in zip(actual, expected):
            assert actual_score == pytest.approx(expected_score, abs=1e-12)


def test_batch_bm25_handles_unprepared_corpus_and_keeps_stable_order():
    corpus = [_doc("none.md", ["beta"]), _doc("first.md", ["alpha"]), _doc("second.md", ["alpha"])]
    idf = recall_gate.build_idf([doc["tokens"] for doc in corpus])
    results = recall_gate.batch_bm25(["alpha", "alpha"], corpus, idf, 1.0)

    assert [index for index, _score in results] == [1, 2, 0]
    assert results[0][1] == pytest.approx(results[1][1], abs=1e-12)
    assert results[2][1] == 0.0


def test_rank_empty_corpus_returns_empty():
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes([])

    assert recall_gate.rank_candidates(
        "alpha", "query.md", [], content_idf, title_idf,
        avg_dl, avg_title_dl,
    ) == []


def test_rank_empty_query_filename_preserves_duplicate_query_weighting():
    corpus = [
        _doc("alpha.md", ["alpha", "alpha", "beta"], ["alpha"]),
        _doc("beta.md", ["beta", "gamma"], ["beta"]),
    ]
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    expected = _legacy_rank(
        "alpha alpha beta", "", corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=10,
    )
    actual = recall_gate.rank_candidates(
        "alpha alpha beta", "", corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=10,
    )

    assert actual == expected


def test_rank_whitelist_participates_in_normalization_but_not_results():
    corpus = [
        _doc("README.md", ["alpha"] * 6, ["alpha"] * 3),
        _doc("candidate.md", ["alpha"], ["alpha"]),
        _doc("other.md", ["beta"], ["beta"]),
    ]
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    query_tokens = recall_gate.tokenize("alpha")
    content_scores = [
        _legacy_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf)
        for doc in corpus
    ]
    title_scores = [
        _legacy_score(query_tokens, doc["title_tokens"], len(doc["title_tokens"]), avg_title_dl, title_idf)
        for doc in corpus
    ]
    assert content_scores[0] > content_scores[1]
    assert title_scores[0] > title_scores[1]

    max_content = max(content_scores)
    max_title = max(title_scores)
    candidate_correct = (
        0.65 * content_scores[1] / max_content
        + 0.10 * title_scores[1] / max_title
    )
    candidate_content_without_readme = max(content_scores[1:])
    candidate_title_without_readme = max(title_scores[1:])
    candidate_if_readme_filtered_first = (
        0.65 * content_scores[1] / candidate_content_without_readme
        + 0.10 * title_scores[1] / candidate_title_without_readme
    )
    assert candidate_correct < candidate_if_readme_filtered_first

    expected = _legacy_rank(
        "alpha", "query.md", corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=10,
    )
    actual = recall_gate.rank_candidates(
        "alpha", "query.md", corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=10,
    )
    assert actual == expected
    assert all(item["path"] != "README.md" for item in actual)


def test_bm25_score_accepts_counter_inputs_like_expanded_legacy_lists():
    query_counter = StdCounter({"alpha": 2, "beta": 1})
    document_counter = StdCounter({"alpha": 3, "beta": 1, "gamma": 2})
    idf = {"alpha": 1.2, "beta": 0.7, "gamma": 0.4}
    doc_tokens = list(document_counter.elements())
    query_tokens = list(query_counter.elements())
    expected = _legacy_score(query_tokens, doc_tokens, len(doc_tokens), 4.0, idf)

    actual = recall_gate.bm25_score(
        query_counter, document_counter, len(doc_tokens), 4.0, idf,
    )

    assert actual == pytest.approx(expected, abs=1e-12)


def test_rank_preserves_raw_float_order_when_rounded_scores_tie():
    corpus = [
        _doc("low.md", ["alpha"] + ["filler"] * 10000, []),
        _doc("high.md", ["alpha"] + ["filler"] * 9999, []),
    ]
    query_text = "alpha"
    query_filename = "query.md"
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    query_tokens = recall_gate.tokenize(query_text)
    raw_scores = [
        _legacy_score(query_tokens, doc["tokens"], doc["token_count"], avg_dl, content_idf)
        for doc in corpus
    ]
    max_raw = max(raw_scores)
    combined_scores = [0.65 * raw_score / max_raw for raw_score in raw_scores]

    assert raw_scores[0] < raw_scores[1]
    assert [round(score, 4) for score in combined_scores] == [0.65, 0.65]

    baseline = recall_gate.rank_candidates(
        query_text, query_filename, corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=2,
    )
    legacy_baseline = _legacy_rank(
        query_text, query_filename, corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=2,
    )
    assert baseline == legacy_baseline
    assert [item["path"] for item in baseline] == ["high.md", "low.md"]
    assert [item["score"] for item in baseline] == [0.65, 0.65]

    top_one = recall_gate.rank_candidates(
        query_text, query_filename, corpus, content_idf, title_idf,
        avg_dl, avg_title_dl, threshold=0.0, top_n=1,
    )
    assert top_one == [baseline[0]]
    assert top_one[0]["path"] == "high.md"

    low_combined = combined_scores[0]
    thresholds = (
        math.nextafter(low_combined, -math.inf),
        low_combined,
        math.nextafter(low_combined, math.inf),
    )
    for threshold in thresholds:
        actual = recall_gate.rank_candidates(
            query_text, query_filename, corpus, content_idf, title_idf,
            avg_dl, avg_title_dl, threshold=threshold, top_n=2,
        )
        expected = _legacy_rank(
            query_text, query_filename, corpus, content_idf, title_idf,
            avg_dl, avg_title_dl, threshold=threshold, top_n=2,
        )
        assert actual == expected, (
            f"threshold={threshold!r} low_combined={low_combined!r} "
            f"actual={actual!r} expected={expected!r}"
        )
        if threshold <= low_combined:
            assert "low.md" in [item["path"] for item in actual]
        else:
            assert [item["path"] for item in actual] == ["high.md"]


def test_rank_matches_frozen_legacy_oracle_for_seeded_corpora():
    randomizer = random.Random(20260908)
    vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon"]
    corpus = []
    for index in range(8):
        tokens = [randomizer.choice(vocabulary) for _ in range(randomizer.randint(0, 9))]
        title_tokens = [randomizer.choice(vocabulary) for _ in range(randomizer.randint(0, 3))]
        corpus.append(_doc(f"candidate-{index}.md", tokens, title_tokens))

    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    for query in ("alpha alpha gamma", "unknown beta", ""):
        expected = _legacy_rank(query, "query-file.md", corpus, content_idf, title_idf, avg_dl, avg_title_dl,
                                threshold=0.15, top_n=4)
        actual = recall_gate.rank_candidates(query, "query-file.md", corpus, content_idf, title_idf, avg_dl,
                                             avg_title_dl, threshold=0.15, top_n=4)
        assert actual == expected


def test_rank_filters_self_and_applies_exact_score_threshold():
    corpus = [
        _doc("query.md", ["alpha", "alpha"], ["alpha"]),
        _doc("alpha-note.md", ["alpha", "alpha"], ["alpha"]),
        _doc("beta-note.md", ["alpha"], []),
    ]
    content_idf, title_idf, avg_dl, avg_title_dl = _indexes(corpus)
    baseline = recall_gate.rank_candidates("alpha alpha", "query.md", corpus, content_idf, title_idf, avg_dl,
                                           avg_title_dl, threshold=0.0, top_n=10)

    assert [item["path"] for item in baseline] == ["alpha-note.md", "beta-note.md"]
    score = baseline[0]["score"]
    at_threshold = recall_gate.rank_candidates("alpha alpha", "query.md", corpus, content_idf, title_idf,
                                               avg_dl, avg_title_dl, threshold=score, top_n=1)
    above_threshold = recall_gate.rank_candidates("alpha alpha", "query.md", corpus, content_idf, title_idf,
                                                  avg_dl, avg_title_dl, threshold=math.nextafter(score, math.inf), top_n=1)

    assert at_threshold == [baseline[0]]
    assert above_threshold == []
    assert all(item["path"] != "query.md" for item in baseline)
    assert all(item["score"] == round(item["score"], 4) for item in baseline)
