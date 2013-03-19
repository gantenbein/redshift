# cython: profile=True
"""
MALT-style dependency parser
"""
cimport cython
import random
from libc.stdlib cimport malloc, free, calloc
from libc.string cimport memcpy, memset
from pathlib import Path
from collections import defaultdict
import sh
import sys
from itertools import izip

from _state cimport *
cimport io_parse
import io_parse
from io_parse cimport Sentence
from io_parse cimport Sentences
from io_parse cimport make_sentence
cimport features
from features cimport FeatureSet

from io_parse import LABEL_STRS, STR_TO_LABEL

import index.hashes
cimport index.hashes

from svm.cy_svm cimport Model, LibLinear, Perceptron

from libc.stdint cimport uint64_t, int64_t
from libc.stdlib cimport qsort

from libcpp.utility cimport pair
from libcpp.vector cimport vector


from cython.operator cimport dereference as deref, preincrement as inc


cdef extern from "sparsehash/dense_hash_map" namespace "google":
    cdef cppclass dense_hash_map[K, D]:
        K& key_type
        D& data_type
        pair[K, D]& value_type
        uint64_t size_type
        cppclass iterator:
            pair[K, D]& operator*() nogil
            iterator operator++() nogil
            iterator operator--() nogil
            bint operator==(iterator) nogil
            bint operator!=(iterator) nogil
        iterator begin()
        iterator end()
        uint64_t size()
        uint64_t max_size()
        bint empty()
        uint64_t bucket_count()
        uint64_t bucket_size(uint64_t i)
        uint64_t bucket(K& key)
        double max_load_factor()
        void max_load_vactor(double new_grow)
        double min_load_factor()
        double min_load_factor(double new_grow)
        void set_resizing_parameters(double shrink, double grow)
        void resize(uint64_t n)
        void rehash(uint64_t n)
        dense_hash_map()
        dense_hash_map(uint64_t n)
        void swap(dense_hash_map&)
        pair[iterator, bint] insert(pair[K, D]) nogil
        void set_empty_key(K&)
        void set_deleted_key(K& key)
        void clear_deleted_key()
        void erase(iterator pos)
        uint64_t erase(K& k)
        void erase(iterator first, iterator last)
        void clear()
        void clear_no_resize()
        pair[iterator, iterator] equal_range(K& k)
        D& operator[](K&) nogil


VOCAB_SIZE = 1e6
TAG_SET_SIZE = 50
cdef double FOLLOW_ERR_PC = 0.90


DEBUG = False 
def set_debug(val):
    global DEBUG
    DEBUG = val

cdef enum:
    ERR
    SHIFT
    REDUCE
    LEFT
    RIGHT
    _n_moves

DEF N_MOVES = 5
assert N_MOVES == _n_moves, "Set N_MOVES compile var to %d" % _n_moves


DEF USE_COLOURS = True

def red(string):
    if USE_COLOURS:
        return u'\033[91m%s\033[0m' % string
    else:
        return string


cdef lmove_to_str(move, label):
    moves = ['E', 'S', 'D', 'L', 'R', 'W', 'V']
    label = LABEL_STRS[label]
    if move == SHIFT:
        return 'S'
    elif move == REDUCE:
        return 'D'
    else:
        return '%s-%s' % (moves[move], label)


def _parse_labels_str(labels_str):
    return [STR_TO_LABEL[l] for l in labels_str.split(',')]


cdef class Parser:
    cdef FeatureSet features
    cdef Perceptron guide
    cdef object model_dir
    cdef size_t beam_width
    cdef TransitionSystem moves
    cdef object add_extra
    cdef object label_set
    cdef object train_alg
    cdef int feat_thresh

    cdef bint label_beam
    cdef object upd_strat

    def __cinit__(self, model_dir, clean=False, train_alg='static',
                  add_extra=True, label_set='MALT', feat_thresh=5,
                  allow_reattach=False, allow_reduce=False,
                  reuse_idx=False, beam_width=1, upd_strat="early", 
                  label_beam=True):
        model_dir = Path(model_dir)
        if not clean:
            params = dict([line.split() for line in model_dir.join('parser.cfg').open()])
            C = float(params['C'])
            train_alg = params['train_alg']
            eps = float(params['eps'])
            add_extra = True if params['add_extra'] == 'True' else False
            label_set = params['label_set']
            feat_thresh = int(params['feat_thresh'])
            allow_reattach = params['allow_reattach'] == 'True'
            allow_reduce = params['allow_reduce'] == 'True'
            l_labels = params['left_labels']
            r_labels = params['right_labels']
            beam_width = int(params['beam_width'])
            upd_strat = params['upd_strat']
            label_beam = params['label_beam'] == 'True'
        if allow_reattach and allow_reduce:
            print 'NM L+D'
        elif allow_reattach:
            print 'NM L'
        elif allow_reduce:
            print 'NM D'
        if beam_width >= 1:
            beam_settings = (beam_width, upd_strat, label_beam)
            print 'Beam settings: k=%d; upd_strat=%s; label_beam=%s' % beam_settings
        self.model_dir = self.setup_model_dir(model_dir, clean)
        labels = io_parse.set_labels(label_set)
        self.features = FeatureSet(len(labels), add_extra)
        self.add_extra = add_extra
        self.label_set = label_set
        self.feat_thresh = feat_thresh
        self.train_alg = train_alg
        self.beam_width = beam_width
        self.upd_strat = upd_strat
        self.label_beam = label_beam
        if clean == True:
            self.new_idx(self.model_dir, self.features.n)
        else:
            self.load_idx(self.model_dir, self.features.n)
        self.moves = TransitionSystem(labels, allow_reattach=allow_reattach,
                                      allow_reduce=allow_reduce)
        if not clean:
            self.moves.set_labels(_parse_labels_str(l_labels), _parse_labels_str(r_labels))
        guide_loc = self.model_dir.join('model')
        n_labels = len(io_parse.LABEL_STRS)
        self.guide = Perceptron(self.moves.max_class, guide_loc)

    def setup_model_dir(self, loc, clean):
        if clean and loc.exists():
            sh.rm('-rf', loc)
        if loc.exists():
            assert loc.is_dir()
        else:
            loc.mkdir()
        sh.git.log(n=1, _out=loc.join('version').open('wb'), _bg=True) 
        return loc

    def train(self, Sentences sents, C=None, eps=None, n_iter=15, held_out=None):
        cdef size_t i, j, n
        cdef Sentence* sent
        cdef Sentences held_out_gold
        cdef Sentences held_out_parse
        # Count classes and labels
        seen_l_labels = set([])
        seen_r_labels = set([])
        for i in range(sents.length):
            sent = &sents.s[i]
            for j in range(1, sent.length - 1):
                label = sent.parse.labels[j]
                if sent.parse.heads[j] > j:
                    seen_l_labels.add(label)
                else:
                    seen_r_labels.add(label)
        move_classes = self.moves.set_labels(seen_l_labels, seen_r_labels)
        self.guide.set_classes(range(move_classes))
        self.write_cfg(self.model_dir.join('parser.cfg'))
        indices = range(sents.length)
        if self.beam_width >= 1:
            self.guide.use_cache = True
        stats = defaultdict(int)
        for n in range(n_iter):
            random.shuffle(indices)
            # Group indices into minibatches of fixed size
            for minibatch in izip(*[iter(indices)] * 1):
                deltas = []
                for i in minibatch:
                    if self.beam_width >= 1:
                        if DEBUG:
                            print ' '.join(sents.strings[i][0])
                        #deltas.append(self.decode_beam(&sents.s[i], self.beam_width,
                        #              stats))
                        deltas.append(self.decode_dyn_beam(&sents.s[i], self.beam_width,
                                      stats))
                    else:
                        self.train_one(n, &sents.s[i], sents.strings[i][0])
                for weights in deltas:
                    self.guide.batch_update(weights)
            print_train_msg(n, self.guide.n_corr, self.guide.total,
                            self.guide.cache.n_hit, self.guide.cache.n_miss,
                            stats)
            if self.feat_thresh > 1:
                self.guide.prune(self.feat_thresh)
            self.guide.n_corr = 0
            self.guide.total = 0
        self.guide.train()

    cdef dict decode_beam(self, Sentence* sent, size_t k, object stats):
        cdef size_t i
        cdef int* costs
        cdef int cost
        cdef size_t* g_heads = sent.parse.heads
        cdef size_t* g_labels = sent.parse.labels
        cdef State * s
        cdef State* parent
        cdef Cont* cont
        cdef Violation violn
        cdef bint halt = False
        cdef int* valid
        self.guide.cache.flush()
        cdef Beam beam = Beam(k, sent.length, self.guide.nr_class,
                              upd_strat=self.upd_strat, add_labels=self.label_beam)
        stats['sents'] += 1
        while not beam.gold.is_finished:
            beam.refresh()
            self._fill_move_scores(sent, beam.psize, beam.parents, beam.next_moves)
            beam.sort_moves()
            self._advance_gold(beam.gold, sent, self.train_alg == 'static')
            for i in range(beam.nr_class):
                cont = &beam.next_moves[i]
                if not cont.is_valid:
                    continue
                if cont.score <= -10000:
                    break
                if not beam.accept(cont.parent, self.moves.moves[cont.clas], cont.score):
                    continue
                parent = beam.parents[cont.parent]
                if self.train_alg == 'static':
                    cost = cont.clas != self.moves.break_tie(parent, g_heads, g_labels)
                else:
                    costs = self.moves.get_costs(parent, g_heads, g_labels)
                    cost = costs[cont.clas]
                    assert cost != -1, cont.clas
                s = beam.add(cont.parent, cont.score, cost)
                self.moves.transition(cont.clas, s)
                if beam.is_full:
                    break
            assert beam.bsize
            if beam.bsize:
                assert beam.gold.t == beam.beam[0].t, '%d vs %d (%d)'
            assert beam.bsize <= beam.k, beam.bsize
            halt = beam.check_violation()
            if halt:
                stats['early'] += 1
                break
            elif beam.beam[0].is_gold:
                self.guide.n_corr += 1
            for i in range(beam.bsize):
                assert beam.beam[i].t == beam.gold.t, '%d vs %d' % (beam.beam[i].t, beam.gold.t)
        self.guide.total += beam.gold.t
        if beam.first_violn is not None:
            violn = beam.pick_violation()
            stats['moves'] += violn.t
            counted = self._count_feats(sent, violn.t, violn.phist, violn.ghist)
            return counted
        else:
            stats['moves'] += beam.gold.t
            return {}

    cdef dict decode_dyn_beam(self, Sentence* sent, size_t max_width, object stats):
        cdef bint cache_hit = False
        cdef Kernel* k
        cdef double* scores
        cdef DynBeam beam = DynBeam(max_width, sent.length, self.guide.nr_class)
        stats['sents'] += 1
        self.guide.use_cache = False
        self.guide.cache.flush()
        while not beam.gold.is_finished:
            self._advance_gold(beam.gold, sent, self.train_alg == 'static')
            for i in range(beam.bsize):
                assert <size_t>beam.beam[i] != 0
                assert <size_t>beam.beam[i].k != 0
                feats = self.features.extract(sent, beam.beam[i].k)
                scores = self.guide.predict_scores(self.features.n, feats)
                for clas in range(self.moves.nr_class):
                    beam.extend_equiv(i, self.moves.labels[clas], self.moves.moves[clas],
                                      clas, scores[clas])
            beam.refresh()
            if self.upd_strat == 'early' and beam.bsize == max_width:
                if beam.gold.score <= beam.beam[max_width - 1].path_score:
                    break
        cdef size_t t = 0
        phist = beam.viterbi_path(beam.best, &t)
        assert beam.gold.t >= t
        counts = self._count_feats(sent, t, phist, beam.gold.history)
        return counts

    cdef int _advance_gold(self, State* s, Sentence* sent, bint use_static) except -1:
        cdef:
            size_t oracle, i
            int* costs
            uint64_t* feats
            double* scores
            bint cache_hit
            double best_score
        fill_kernel(s)
        scores = self.guide.cache.lookup(sizeof(s.kernel), <void*>&s.kernel, &cache_hit)
        if not cache_hit:
            feats = self.features.extract(sent, &s.kernel)
            self.guide.model.get_scores(self.features.n, feats, scores)
        if use_static:
            oracle = self.moves.break_tie(s, sent.parse.heads, sent.parse.labels)
        else:
            costs = self.moves.get_costs(s, sent.parse.heads, sent.parse.labels)
            best_score = -1000000
            for i in range(self.moves.nr_class):
                if costs[i] == 0 and scores[i] > best_score:
                    oracle = i
                    best_score = scores[i]
            assert best_score > -1000000
        s.score += scores[oracle]
        if DEBUG:
            print s.t, "Adv gold", oracle, s.stack_len, s.top, s.heads[s.top], s.i
        self.moves.transition(oracle, s)

    cdef int _fill_move_scores(self, Sentence* sent, size_t k, State** parents,
            Cont* next_moves) except -1:
        cdef size_t parent_idx, child_idx
        cdef State* parent
        cdef uint64_t* feats
        cdef int* valid
        cdef size_t n_feats = self.features.n
        cdef bint cache_hit = False
        cdef size_t move_idx = 0
        cdef size_t n_valid = 0
        for parent_idx in range(k):
            parent = parents[parent_idx]
            fill_kernel(parent)
            scores = self.guide.cache.lookup(sizeof(parent.kernel),
                    <void*>&parent.kernel, &cache_hit)
            if not cache_hit:
                feats = self.features.extract(sent, &parent.kernel)
                self.guide.model.get_scores(n_feats, feats, scores)
            valid = self.moves.get_valid(parent)
            for child_idx in range(self.guide.nr_class):
                next_moves[move_idx].parent = parent_idx
                next_moves[move_idx].clas = child_idx
                if valid[child_idx] == 1:
                    parent.nr_kids += 1
                    next_moves[move_idx].score = scores[child_idx] + parent.score
                    next_moves[move_idx].is_valid = True
                    n_valid += 1
                else:
                    next_moves[move_idx].score = -1000001
                    next_moves[move_idx].is_valid = False
                move_idx += 1
        assert n_valid != 0
        return n_valid

    cdef dict _count_feats(self, Sentence* sent, size_t t, size_t* phist, size_t* ghist):
        cdef size_t d, i, f
        cdef size_t n_feats = self.features.n
        cdef uint64_t* feats
        cdef size_t clas
        cdef State* gold_state = init_state(sent.length)
        cdef State* pred_state = init_state(sent.length)
        # Find where the states diverge
        for d in range(t):
            if ghist[d] == phist[d]:
                if DEBUG:
                    print "Common:", ghist[d], gold_state.stack_len, gold_state.top, gold_state.heads[gold_state.top], gold_state.i
                self.moves.transition(ghist[d], gold_state)
                self.moves.transition(phist[d], pred_state)
            else:
                break
        else:
            return {}
        cdef dict counts = {}
        for i in range(d, t):
            fill_kernel(gold_state)
            feats = self.features.extract(sent, &gold_state.kernel)
            clas = ghist[i]
            counts.setdefault(clas, {})
            for f in range(n_feats):
                if feats[f] == 0:
                    break
                counts[clas].setdefault(feats[f], 0)
                counts[clas][feats[f]] += 1
            if DEBUG:
                print "Gold: ", clas, gold_state.stack_len, gold_state.top, gold_state.heads[gold_state.top], gold_state.i
            self.moves.transition(clas, gold_state)
        free_state(gold_state)
        for i in range(d, t):
            fill_kernel(pred_state)
            feats = self.features.extract(sent, &pred_state.kernel)
            clas = phist[i]
            counts.setdefault(clas, {})
            for f in range(n_feats):
                if feats[f] == 0:
                    break
                counts[clas].setdefault(feats[f], 0)
                counts[clas][feats[f]] -= 1
            if DEBUG:
                print d, t, 'count', clas, pred_state.top, pred_state.heads[pred_state.top], pred_state.i
            self.moves.transition(clas, pred_state)
        free_state(pred_state)
        return counts

    cdef int train_one(self, int iter_num, Sentence* sent, py_words) except -1:
        cdef int* valid
        cdef int* costs
        cdef size_t* g_labels = sent.parse.labels
        cdef size_t* g_heads = sent.parse.heads

        cdef size_t n_feats = self.features.n
        cdef State* s = init_state(sent.length)
        cdef size_t move = 0
        cdef size_t label = 0
        cdef size_t _ = 0
        cdef bint online = self.train_alg == 'online'
        if DEBUG:
            print ' '.join(py_words)
        while not s.is_finished:
            fill_kernel(s)
            feats = self.features.extract(sent, &s.kernel)
            valid = self.moves.get_valid(s)
            pred = self.predict(n_feats, feats, valid, &s.guess_labels[s.i])
            if online:
                costs = self.moves.get_costs(s, g_heads, g_labels)
                gold = self.predict(n_feats, feats, costs, &_) if costs[pred] != 0 else pred
            else:
                gold = self.moves.break_tie(s, g_heads, g_labels)
            self.guide.update(pred, gold, n_feats, feats, 1)
            if online and iter_num >= 2 and random.random() < FOLLOW_ERR_PC:
                self.moves.transition(pred, s)
            else:
                self.moves.transition(gold, s)
        free_state(s)

    def add_parses(self, Sentences sents, Sentences gold=None, k=None):
        cdef:
            size_t i
        if k == None:
            k = self.beam_width
        self.guide.nr_class = self.moves.nr_class
        for i in range(sents.length):
            if k <= 1:
                self.parse(&sents.s[i])
            else:
                self.beam_parse(&sents.s[i], k)
        if gold is not None:
            return sents.evaluate(gold)

    cdef int parse(self, Sentence* sent) except -1:
        cdef State* s
        cdef size_t move = 0
        cdef size_t label = 0
        cdef size_t clas
        cdef size_t n_preds = self.features.n
        cdef uint64_t* feats
        cdef double* scores
        s = init_state(sent.length)
        sent.parse.n_moves = 0
        self.guide.cache.flush()
        while not s.is_finished:
            fill_kernel(s)
            feats = self.features.extract(sent, &s.kernel)
            clas = self.predict(n_preds, feats, self.moves.get_valid(s),
                                  &s.guess_labels[s.i])
            sent.parse.moves[s.t] = clas
            self.moves.transition(clas, s)
        sent.parse.n_moves = s.t
        # No need to copy heads for root and start symbols
        for i in range(1, sent.length - 1):
            assert s.heads[i] != 0
            sent.parse.heads[i] = s.heads[i]
            sent.parse.labels[i] = s.labels[i]
        free_state(s)
    
    cdef int beam_parse(self, Sentence* sent, size_t k) except -1:
        cdef size_t i, c, n_valid
        cdef State* s
        cdef State* new
        cdef Cont* cont
        cdef Beam beam = Beam(k, sent.length, self.guide.nr_class)
        self.guide.cache.flush()
        while not beam.beam[0].is_finished:
            beam.refresh()
            assert beam.psize
            n_valid = self._fill_move_scores(sent, beam.psize, beam.parents,
                                             beam.next_moves)
            beam.sort_moves()
            for c in range(self.moves.nr_class):
                cont = &beam.next_moves[c]
                #if not beam.accept(cont.parent, self.moves.moves[cont.clas], cont.score):
                #    continue
                if not cont.is_valid:
                    continue
                s = beam.add(cont.parent, cont.score, False)
                self.moves.transition(cont.clas, s)
                if beam.is_full:
                    break
            assert beam.bsize != 0
        s = beam.best_p()
        sent.parse.n_moves = s.t
        for i in range(s.t):
            sent.parse.moves[i] = s.history[i]
        # No need to copy heads for root and start symbols
        for i in range(1, sent.length - 1):
            assert s.heads[i] != 0
            sent.parse.heads[i] = s.heads[i]
            sent.parse.labels[i] = s.labels[i]

    cdef int predict(self, uint64_t n_preds, uint64_t* feats, int* valid,
                     size_t* rlabel) except -1:
        cdef:
            size_t i
            double score
            size_t clas, best_valid, best_right
            double* scores

        cdef size_t right_move = 0
        cdef double valid_score = -10000
        cdef double right_score = -10000
        scores = self.guide.predict_scores(n_preds, feats)
        seen_valid = False
        for clas in range(self.guide.nr_class):
            score = scores[clas]
            if valid[clas] == 1 and score > valid_score:
                best_valid = clas
                valid_score = score
                seen_valid = True
            if self.moves.r_end > clas >= self.moves.r_start and score > right_score:
                best_right = clas
                right_score = score
        assert seen_valid
        rlabel[0] = self.moves.labels[best_right]
        return best_valid

    def save(self):
        self.guide.save(self.model_dir.join('model'))

    def load(self):
        self.guide.load(self.model_dir.join('model'))

    def new_idx(self, model_dir, size_t n_predicates):
        index.hashes.init_word_idx(model_dir.join('words'))
        index.hashes.init_pos_idx(model_dir.join('pos'))

    def load_idx(self, model_dir, size_t n_predicates):
        model_dir = Path(model_dir)
        index.hashes.load_word_idx(model_dir.join('words'))
        index.hashes.load_pos_idx(model_dir.join('pos'))
   
    def write_cfg(self, loc):
        with loc.open('w') as cfg:
            cfg.write(u'model_dir\t%s\n' % self.model_dir)
            cfg.write(u'C\t%s\n' % self.guide.C)
            cfg.write(u'eps\t%s\n' % self.guide.eps)
            cfg.write(u'train_alg\t%s\n' % self.train_alg)
            cfg.write(u'add_extra\t%s\n' % self.add_extra)
            cfg.write(u'label_set\t%s\n' % self.label_set)
            cfg.write(u'feat_thresh\t%d\n' % self.feat_thresh)
            cfg.write(u'allow_reattach\t%s\n' % self.moves.allow_reattach)
            cfg.write(u'allow_reduce\t%s\n' % self.moves.allow_reduce)
            cfg.write(u'left_labels\t%s\n' % ','.join(self.moves.left_labels))
            cfg.write(u'right_labels\t%s\n' % ','.join(self.moves.right_labels))
            cfg.write(u'beam_width\t%d\n' % self.beam_width)
            cfg.write(u'upd_strat\t%s\n' % self.upd_strat)
            cfg.write(u'label_beam\t%s\n' % self.label_beam)
        
    def get_best_moves(self, Sentences sents, Sentences gold):
        """Get a list of move taken/oracle move pairs for output"""
        cdef State* s
        cdef size_t n
        cdef size_t move = 0
        cdef size_t label = 0
        cdef object best_moves
        cdef size_t i
        cdef int* costs
        cdef size_t* g_labels
        cdef size_t* g_heads
        cdef size_t clas, parse_class
        best_moves = []
        for i in range(sents.length):
            sent = &sents.s[i]
            g_labels = gold.s[i].parse.labels
            g_heads = gold.s[i].parse.heads
            n = sent.length
            s = init_state(n)
            sent_moves = []
            tokens = sents.strings[i][0]
            while not s.is_finished:
                costs = self.moves.get_costs(s, g_heads, g_labels)
                best_strs = []
                best_ids = set()
                for clas in range(self.moves.nr_class):
                    if costs[clas] == 0:
                        move = self.moves.moves[clas]
                        label = self.moves.labels[clas]
                        if move not in best_ids:
                            best_strs.append(lmove_to_str(move, label))
                        best_ids.add(move)
                best_strs = ','.join(best_strs)
                best_id_str = ','.join(map(str, sorted(best_ids)))
                parse_class = sent.parse.moves[s.t]
                state_str = transition_to_str(s, self.moves.moves[parse_class],
                                              self.moves.labels[parse_class],
                                              tokens)
                parse_move_str = lmove_to_str(move, label)
                if move not in best_ids:
                    parse_move_str = red(parse_move_str)
                sent_moves.append((best_id_str, int(move),
                                  best_strs, parse_move_str,
                                  state_str))
                self.moves.transition(parse_class, s)
            free_state(s)
            best_moves.append((u' '.join(tokens), sent_moves))
        return best_moves


cdef class Beam:
    cdef State** parents
    cdef State** beam
    cdef Cont* next_moves
    cdef State* gold
    cdef size_t n_labels
    cdef size_t nr_class
    cdef size_t k
    cdef size_t bsize
    cdef size_t psize
    cdef Violation first_violn
    cdef Violation max_violn
    cdef Violation last_violn
    cdef Violation cost_violn
    cdef bint is_full
    cdef bint early_upd
    cdef bint max_upd
    cdef bint late_upd
    cdef bint cost_upd
    cdef bint add_labels
    cdef bint** seen_moves

    def __cinit__(self, size_t k, size_t length, size_t nr_class, upd_strat='early',
                  add_labels=True):
        cdef size_t i
        cdef Cont* cont
        cdef State* s
        self.n_labels = len(io_parse.LABEL_STRS)
        self.k = k
        self.parents = <State**>malloc(k * sizeof(State*))
        self.beam = <State**>malloc(k * sizeof(State*))
        for i in range(k):
            self.parents[i] = init_state(length)
        for i in range(k):
            self.beam[i] = init_state(length)
        self.gold = init_state(length)
        self.bsize = 1
        self.psize = 0
        self.is_full = self.bsize >= self.k
        self.nr_class = nr_class * k
        self.next_moves = <Cont*>malloc(self.nr_class * sizeof(Cont))
        self.seen_moves = <bint**>malloc(self.nr_class * sizeof(bint*))
        for i in range(self.nr_class):
            self.next_moves[i] = Cont(score=-10000, clas=0, parent=0, is_gold=False, is_valid=False)
            self.seen_moves[i] = <bint*>calloc(N_MOVES, sizeof(bint))
        self.first_violn = None
        self.max_violn = None
        self.last_violn = None
        self.early_upd = False
        self.cost_upd = False
        self.add_labels = add_labels
        self.late_upd = False
        self.max_upd = False
        self.cost_upd = False
        if upd_strat == 'early':
            self.early_upd = True
        elif upd_strat == 'late':
            self.late_upd = True
        elif upd_strat == 'max':
            self.max_upd = True
        elif upd_strat == 'cost':
            self.cost_upd = True
        else:
            raise StandardError, upd_strat

    cdef sort_moves(self):
        qsort(<void*>self.next_moves, self.nr_class, sizeof(Cont), cmp_contn)

    cdef bint accept(self, size_t parent, size_t move, double score):
        if self.seen_moves[parent][move] and not self.add_labels:
            return False
        self.seen_moves[parent][move] = True
        return True

    cdef State* add(self, size_t par_idx, double score, int cost) except NULL:
        cdef State* parent = self.parents[par_idx]
        assert par_idx < self.psize
        assert not self.is_full
        # TODO: Why's this broken?
        # If there are no more children coming, use the same state object instead
        # of cloning it
        #if parent.nr_kids > 1:
        copy_state(self.beam[self.bsize], parent)
        #else:
        #    self.parents[par_idx] = self.beam[self.bsize]
        #    self.beam[self.bsize] = parent
        #    parent.nr_kids -= 1
        cdef State* ext = self.beam[self.bsize]
        ext.score = score
        ext.is_gold = ext.is_gold and cost == 0
        ext.cost += cost
        self.bsize += 1
        self.is_full = self.bsize >= self.k
        return ext

    cdef bint check_violation(self):
        cdef Violation violn
        cdef bint out_of_beam
        if self.bsize < self.k:
            return False
        if not self.beam[0].is_gold:
            if self.gold.score <= self.beam[0].score:
                out_of_beam = (not self.beam[self.k - 1].is_gold) and \
                        self.gold.score <= self.beam[self.k - 1].score
                violn = Violation()
                violn.set(self.beam[0], self.gold, out_of_beam)
                self.last_violn = violn
                if self.first_violn == None:
                    self.first_violn = violn
                    self.max_violn = violn
                    self.cost_violn = violn
                else:
                    if self.cost_violn.cost < violn.cost:
                        self.cost_violn = violn
                    if self.max_violn.delta <= violn.delta:
                        self.max_violn = violn
                        if self.cost_violn.cost == violn.cost:
                            self.cost_violn = violn
                return out_of_beam and self.early_upd
        return False

    cdef Violation pick_violation(self):
        assert self.first_violn is not None
        if self.early_upd:
            return self.first_violn
        elif self.max_upd:
            return self.max_violn
        elif self.late_upd:
            return self.last_violn
        elif self.cost_upd:
            return self.cost_violn
        else:
            raise StandardError, self.upd_strat

    cdef State* best_p(self) except NULL:
        if self.bsize != 0:
            return self.beam[0]
        else:
            raise StandardError

    cdef refresh(self):
        cdef size_t i, j
        for i in range(self.nr_class):
            for j in range(N_MOVES):
                self.seen_moves[i][j] = False

        for i in range(self.bsize):
            copy_state(self.parents[i], self.beam[i])
        self.psize = self.bsize
        self.is_full = False
        self.bsize = 0

    def __dealloc__(self):
        for i in range(self.k):
            free_state(self.beam[i])
        for i in range(self.k):
            free_state(self.parents[i])
        for i in range(self.nr_class):
            free(self.seen_moves[i])
        free(self.next_moves)
        free(self.beam)
        free(self.parents)
        free_state(self.gold)

cdef class Violation:
    """
    A gold/prediction pair where the g.score < p.score
    """
    cdef size_t t
    cdef size_t* ghist
    cdef size_t* phist
    cdef double delta
    cdef int cost
    cdef bint out_of_beam

    def __cinit__(self):
        self.out_of_beam = False
        self.t = 0
        self.delta = 0.0
        self.cost = 0

    cdef int set(self, State* p, State* g, bint out_of_beam) except -1:
        self.delta = p.score - g.score
        self.cost = p.cost
        assert g.t == p.t, '%d vs %d' % (g.t, p.t)
        self.t = g.t
        self.ghist = <size_t*>malloc(self.t * sizeof(size_t))
        memcpy(self.ghist, g.history, self.t * sizeof(size_t))
        self.phist = <size_t*>malloc(self.t * sizeof(size_t))
        memcpy(self.phist, p.history, self.t * sizeof(size_t))
        self.out_of_beam = out_of_beam

    def __dealloc__(self):
        free(self.ghist)
        free(self.phist)


cdef struct EquivClass:
    size_t nr_ptr
    double path_score
    size_t best_p
    size_t best_gp
    size_t* moves_from
    double* scores_from
    EquivClass** parents
    EquivClass** stack_parents
    Kernel* k


cdef class DynBeam:
    cdef State* gold
    cdef size_t bsize
    cdef size_t max_width
    cdef size_t sent_len
    cdef size_t nr_class
    cdef size_t nr_equiv
    cdef size_t nr_label
    cdef double delta
    cdef dense_hash_map[uint64_t, size_t] table
    cdef dense_hash_map[size_t, size_t] all_states
    cdef EquivClass** beam
    cdef EquivClass* best
    cdef EquivClass* violn
    cdef size_t* _viterbi_path
    cdef double max_delta
    cdef double max_score

    def __cinit__(self, size_t k, size_t sent_len, size_t nr_class):
        self.gold = init_state(sent_len)
        self.max_width = k
        self.sent_len = sent_len
        self.nr_class = nr_class
        self.nr_label = 50
        self.delta = -1
        self.max_score = -10000
        self.nr_equiv = 0
        self.table = dense_hash_map[uint64_t, size_t]()
        self.all_states = dense_hash_map[size_t, size_t]()
        self.table.set_empty_key(0)
        self.all_states.set_empty_key(0)

        self.beam = <EquivClass**>malloc(self.max_width * sizeof(EquivClass*))
        self.bsize = 1
        self.beam[0] = self._init_equiv()
        self.violn = NULL
        self.best = self.beam[0]
        self._viterbi_path = <size_t*>calloc(sent_len * 2, sizeof(size_t))

    cdef size_t* viterbi_path(self, EquivClass* eq, size_t* t):
        cdef size_t par_idx = eq.best_p
        cdef size_t gp_idx = eq.best_gp
        memset(self._viterbi_path, 0, self.sent_len * 2)
        # States start with the first word on the stack, so halt one early to get
        # the same number of moves
        cdef size_t i = 0
        while eq.parents[0].nr_ptr != 0:
            self._viterbi_path[i] = eq.moves_from[par_idx]
            gp_idx = eq.best_gp
            eq = eq.parents[par_idx]
            par_idx = gp_idx
            i += 1
        t[0] = i
        # Reverse the list
        for i in range(t[0] / 2):
            first = self._viterbi_path[i]
            last = self._viterbi_path[t[0] - (i + 1)]
            self._viterbi_path[i] = last
            self._viterbi_path[t[0] - (i + 1)] = first
        return self._viterbi_path
    
    cdef int refresh(self) except -1:
        cdef dense_hash_map[uint64_t, size_t].iterator it
        cdef pair[uint64_t, size_t] data
        cdef size_t addr
        cdef double score
        agenda = []
        #cdef pair[uint64_t, size_t] data
        #cdef vector[pair[double, size_t]] agenda
        it = self.table.begin()
        table_size = 0
        while it != self.table.end():
            data = deref(it)
            assert data.second != 0
            addr = <size_t>data.second
            equiv_class = <EquivClass*>addr
            score = equiv_class.path_score
            agenda.append((score, addr))
        #    agenda.push_back(pair(equiv_class.path_score, data.second))
            inc(it)
            table_size += 1
        self.table.clear()
        agenda.sort(reverse=True)
        for i in range(self.max_width):
            addr = <size_t>agenda[i][1]
            equiv = <EquivClass*>addr
            for j in range(equiv.nr_ptr):
                assert <size_t>equiv.stack_parents[j] != 0
            self.beam[i] = equiv
            if i == (len(agenda) - 1):
                break
        self.bsize = i + 1
        self.best = self.beam[0]
        if DEBUG:
            print self.bsize, 'Current best:', self.beam[0].path_score, self.best.best_p, self.nr_class, self.best.nr_ptr
            print 'Refresh', self.best.moves_from[self.best.best_p], self.best.k.s0, self.best.k.hs0, self.best.k.i
        cdef double delta = self.best.path_score - self.gold.score
        if delta > self.max_delta:
            self.max_delta = delta
            self.violn = self.best
        self.nr_equiv = 0

    cdef int extend_equiv(self, size_t i, size_t label, size_t move,
                          size_t clas, double score) except -1:
        cdef Kernel* cont
        cdef EquivClass* eq = self.beam[i]
        cdef Kernel* k = self.beam[i].k
        cdef size_t j
        if move == SHIFT and k.i == self.sent_len:
            return 0
        elif move == RIGHT and (k.i == self.sent_len or not k.s0):
            return 0
        elif move == REDUCE and (k.s0 == 0 or k.hs0 == 0):
            return 0
        elif move == LEFT and (k.hs0 or not k.s0):
            return 0
        if move == SHIFT:
            cont = kernel_from_s(k)
            assert cont.i == k.i + 1
            self._push(cont, i, 0, score)
        elif move == RIGHT:
            cont = kernel_from_r(k, label)
            assert cont.i == k.i + 1
            self._push(cont, i, clas, score)
        elif move == REDUCE and eq.nr_ptr:
            #j = eq.best_p
            for j in range(eq.nr_ptr):
                assert <size_t>eq.stack_parents[j] != 0
                cont = kernel_from_d(k, eq.stack_parents[j].k)
                assert cont.i == k.i
                self._pop(cont, i, j, 1, score)
        elif move == LEFT and eq.nr_ptr:
            #j = eq.best_p
            for j in range(eq.nr_ptr):
                assert <size_t>eq.stack_parents[j] != 0
                cont = kernel_from_l(k, eq.stack_parents[j].k, label)
                assert cont.i == k.i
                self._pop(cont, i, j, clas, score)

    cdef int _push(self, Kernel* k, size_t par_idx, size_t clas, double score) except -1:
        cdef size_t addr = self._lookup(k)
        cdef EquivClass* ext = <EquivClass*>addr
        cdef EquivClass* parent = self.beam[par_idx]
        cdef EquivClass* gp
        assert <size_t>parent != 0
        assert clas < 100
        ext.parents[ext.nr_ptr] = parent
        ext.stack_parents[ext.nr_ptr] = parent
        ext.moves_from[ext.nr_ptr] = clas
        ext.scores_from[ext.nr_ptr] = score
        path_score = parent.path_score + score
        if DEBUG:
            print 'U %d onto %d via %d at %s, %s' % (<size_t>ext, <size_t>parent, clas, path_score, score)
        if path_score > ext.path_score or ext.nr_ptr == 0:
            ext.path_score = path_score
            ext.best_p = ext.nr_ptr
            ext.best_gp = parent.best_p
            if path_score > self.max_score:
                self.max_score = path_score
                self.best = ext
        ext.nr_ptr += 1
        assert ext.best_p < ext.nr_ptr

    cdef int _pop(self, Kernel* k, size_t par_idx, size_t gp_idx, size_t clas, double score) except -1:
        cdef EquivClass* gp 
        cdef EquivClass* a 
        cdef EquivClass* ext = <EquivClass*>self._lookup(k)
        cdef EquivClass* parent = self.beam[par_idx]
        assert clas < 100
        if parent.nr_ptr:
            a = parent.stack_parents[gp_idx]
            gp = a.stack_parents[a.best_p] if a.nr_ptr != 0 else a
        else:
            gp = parent
        assert <size_t>gp != 0, '%d, best %d' % (a.nr_ptr, a.best_p)
        ext.parents[ext.nr_ptr] = parent
        ext.stack_parents[ext.nr_ptr] = gp
        ext.moves_from[ext.nr_ptr] = clas
        ext.scores_from[ext.nr_ptr] = score
        # Because we care about the grandparent, we have to recalculate the parent's
        # path score --- otherwise, it might refer to a path from a different GP
        path_score = parent.parents[gp_idx].path_score + parent.scores_from[gp_idx] + score
        if DEBUG:
            print 'O %d from %d via %d at %s, %s' % (<size_t>ext, <size_t>parent, clas, path_score, score)

        if path_score > ext.path_score or ext.nr_ptr == 0:
            ext.path_score = path_score
            ext.best_p = ext.nr_ptr
            ext.best_gp = gp_idx
            if path_score > self.max_score:
                self.max_score = path_score
                self.best = ext
        ext.nr_ptr += 1
        assert ext.best_p < ext.nr_ptr

    cdef size_t _lookup(self, Kernel* k) except 0:
        cdef EquivClass* equiv
        cdef uint64_t hashed = hash_kernel(k)
        cdef size_t addr = self.table[hashed]
        if addr == 0:
            equiv = <EquivClass*>malloc(sizeof(EquivClass))
            equiv.nr_ptr = 0
            equiv.path_score = 0
            equiv.parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
            equiv.stack_parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
            equiv.moves_from = <size_t*>calloc(self.nr_class, sizeof(size_t))
            equiv.scores_from = <double*>calloc(self.nr_class, sizeof(double))
            equiv.k = k
            addr = <size_t>equiv
            self.table[hashed] = <size_t>addr
            self.all_states[addr] = 1
            self.nr_equiv += 1
        else:
            equiv = <EquivClass*>addr
        assert equiv.nr_ptr < 100000
        return addr

    cdef EquivClass* _init_equiv(self):
        cdef EquivClass* first = <EquivClass*>malloc(sizeof(EquivClass))
        cdef size_t addr = <size_t>first
        first.nr_ptr = 0
        first.path_score = 0
        first.parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
        first.stack_parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
        first.moves_from = <size_t*>calloc(self.nr_class, sizeof(size_t))
        first.scores_from = <double*>calloc(self.nr_class, sizeof(double))
        cdef Kernel* k = <Kernel*>malloc(sizeof(Kernel))
        memset(k, 0, sizeof(Kernel))
        first.k = k
        first.k.i = 1

        cdef uint64_t hashed = hash_kernel(first.k)
        self.all_states[addr] = 1
        cdef EquivClass* second = <EquivClass*>malloc(sizeof(EquivClass))
        second.nr_ptr = 1
        second.path_score = 0
        second.parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
        second.stack_parents = <EquivClass**>calloc(self.nr_class, sizeof(EquivClass*))
        second.moves_from = <size_t*>calloc(self.nr_class, sizeof(size_t))
        second.scores_from = <double*>calloc(self.nr_class, sizeof(double))
        k = <Kernel*>malloc(sizeof(Kernel))
        memset(k, 0, sizeof(Kernel))
        second.k = k
        second.k.i = 2
        second.k.s0 = 1
        second.parents[0] = first
        second.stack_parents[0] = first
        second.scores_from[0] = 0
        second.moves_from[0] = 0
        second.best_p = 0
        second.best_gp = 0
        hashed = hash_kernel(second.k)
        self.all_states[<size_t>second] = 1
        return second

    def __dealloc__(self):
        cdef dense_hash_map[size_t, size_t].iterator it
        cdef pair[size_t, size_t] data
        cdef size_t addr
        it = self.all_states.begin()
        freed = set()
        while it != self.all_states.end():
            data = deref(it)
            addr = <size_t>data.first
            inc(it)
            if addr in freed:
                continue
            freed.add(addr)
            equiv = <EquivClass*>addr
            free(equiv.k)
            free(equiv.parents)
            free(equiv.stack_parents)
            free(equiv.scores_from)
            free(equiv.moves_from)
            free(equiv)
        free_state(self.gold)
        free(self.beam)
        free(self._viterbi_path)

cdef class TransitionSystem:
    cdef bint allow_reattach
    cdef bint allow_reduce
    cdef size_t n_labels
    cdef object py_labels
    cdef int* _costs
    cdef size_t* labels
    cdef size_t* moves
    cdef size_t* l_classes
    cdef size_t* r_classes
    cdef list left_labels
    cdef list right_labels
    cdef size_t nr_class
    cdef size_t max_class
    cdef size_t s_id
    cdef size_t d_id
    cdef size_t l_start
    cdef size_t l_end
    cdef size_t r_start
    cdef size_t r_end

    def __cinit__(self, object labels, allow_reattach=False,
                  allow_reduce=False):
        self.n_labels = len(labels)
        self.py_labels = labels
        self.allow_reattach = allow_reattach
        self.allow_reduce = allow_reduce
        self.nr_class = 0
        max_classes = N_MOVES * len(labels)
        self.max_class = max_classes
        self._costs = <int*>calloc(max_classes, sizeof(int))
        self.labels = <size_t*>calloc(max_classes, sizeof(size_t))
        self.moves = <size_t*>calloc(max_classes, sizeof(size_t))
        self.l_classes = <size_t*>calloc(self.n_labels, sizeof(size_t))
        self.r_classes = <size_t*>calloc(self.n_labels, sizeof(size_t))
        self.s_id = 0
        self.d_id = 1
        self.l_start = 2
        self.l_end = 0
        self.r_start = 0
        self.r_end = 0

    def set_labels(self, left_labels, right_labels):
        self.left_labels = [self.py_labels[l] for l in sorted(left_labels)]
        self.right_labels = [self.py_labels[l] for l in sorted(right_labels)]
        self.labels[self.s_id] = 0
        self.labels[self.d_id] = 0
        self.moves[self.s_id] = <int>SHIFT
        self.moves[self.d_id] = <int>REDUCE
        clas = self.l_start
        for label in left_labels:
            self.moves[clas] = <int>LEFT
            self.labels[clas] = label
            self.l_classes[label] = clas
            clas += 1
        self.l_end = clas
        self.r_start = clas
        for label in right_labels:
            self.moves[clas] = <int>RIGHT
            self.labels[clas] = label
            self.r_classes[label] = clas
            clas += 1
        self.r_end = clas
        self.nr_class = clas
        return clas
        
    cdef int transition(self, size_t clas, State *s) except -1:
        cdef size_t head, child, new_parent, new_child, c, gc, move, label
        move = self.moves[clas]
        label = self.labels[clas]
        s.history[s.t] = clas
        s.t += 1 
        if move == SHIFT:
            push_stack(s)
        elif move == REDUCE:
            if s.heads[s.top] == 0:
                assert self.allow_reduce
                assert s.second != 0
                assert s.second < s.top
                add_dep(s, s.second, s.top, s.guess_labels[s.top])
            pop_stack(s)
        elif move == LEFT:
            child = pop_stack(s)
            if s.heads[child] != 0:
                del_r_child(s, s.heads[child])
            head = s.i
            add_dep(s, head, child, label)
        elif move == RIGHT:
            child = s.i
            head = s.top
            add_dep(s, head, child, label)
            push_stack(s)
        else:
            print move
            print label
            raise StandardError(clas)
        if s.i == (s.n - 1):
            s.at_end_of_buffer = True
        if s.at_end_of_buffer and s.stack_len == 1:
            s.is_finished = True

  
    cdef int* get_costs(self, State* s, size_t* heads, size_t* labels) except NULL:
        cdef size_t i
        cdef int* costs = self._costs
        for i in range(self.nr_class):
            costs[i] = -1
        if s.stack_len == 1 and not s.at_end_of_buffer:
            costs[self.s_id] = 0
        if not s.at_end_of_buffer:
            costs[self.s_id] = self.s_cost(s, heads, labels)
            r_cost = self.r_cost(s, heads, labels)
            if r_cost != -1:
                for i in range(self.r_start, self.r_end):
                    if heads[s.i] == s.top and self.labels[i] != labels[s.i]:
                        costs[i] = r_cost + 1
                    else:
                        costs[i] = r_cost
        if s.stack_len >= 2:
            costs[self.d_id] = self.d_cost(s, heads, labels)
            l_cost = self.l_cost(s, heads, labels)
            if l_cost != -1:
                for i in range(self.l_start, self.l_end):
                    if heads[s.top] == s.i and self.labels[i] != labels[s.top]:
                        costs[i] = l_cost + 1
                    else:
                        costs[i] = l_cost
        return costs

    cdef int* get_valid(self, State* s):
        cdef size_t i
        cdef int* valid = self._costs
        for i in range(self.nr_class):
            valid[i] = -1
        if not s.at_end_of_buffer:
            valid[self.s_id] = 1
            if s.stack_len == 1:
                return valid
            else:
                for i in range(self.r_start, self.r_end):
                    valid[i] = 1
        else:
            valid[self.s_id] = -1
        if s.stack_len != 1:
            if s.heads[s.top] != 0:
                valid[self.d_id] = 1
            if self.allow_reattach or s.heads[s.top] == 0:
                for i in range(self.l_start, self.l_end):
                    valid[i] = 1
        if s.stack_len >= 3 and self.allow_reduce:
            valid[self.d_id] = 1
        return valid  

    cdef int break_tie(self, State* s, size_t* heads, size_t* labels) except -1:
        if s.stack_len == 1:
            return self.s_id
        elif not s.at_end_of_buffer and heads[s.i] == s.top:
            return self.r_classes[labels[s.i]]
        elif heads[s.top] == s.i and (self.allow_reattach or s.heads[s.top] == 0):
            return self.l_classes[labels[s.top]]
        elif self.d_cost(s, heads, labels) == 0:
            return self.d_id
        elif not s.at_end_of_buffer and self.s_cost(s, heads, labels) == 0:
            return self.s_id
        else:
            return self.nr_class + 1

    cdef int s_cost(self, State *s, size_t* heads, size_t* labels):
        cdef int cost = 0
        cdef size_t i, stack_i
        cost += has_child_in_stack(s, s.i, heads)
        cost += has_head_in_stack(s, s.i, heads)
        return cost

    cdef int r_cost(self, State *s, size_t* heads, size_t* labels):
        cdef int cost = 0
        cdef size_t i, buff_i, stack_i
        if heads[s.i] == s.top:
            return 0
        cost += has_head_in_buffer(s, s.i, heads)
        cost += has_child_in_stack(s, s.i, heads)
        cost += has_head_in_stack(s, s.i, heads)
        return cost

    cdef int d_cost(self, State *s, size_t* g_heads, size_t* g_labels):
        cdef int cost = 0
        if s.heads[s.top] == 0 and not self.allow_reduce:
            return -1
        if g_heads[s.top] == 0 and (s.stack_len == 2 or not self.allow_reattach):
            cost += 1
        cost += has_child_in_buffer(s, s.top, g_heads)
        if self.allow_reattach:
            cost += has_head_in_buffer(s, s.top, g_heads)
        return cost

    cdef int l_cost(self, State *s, size_t* heads, size_t* labels):
        cdef size_t buff_i, i
        cdef int cost = 0
        if s.heads[s.top] != 0 and not self.allow_reattach:
            return -1
        if heads[s.top] == s.i:
            return 0
        cost +=  has_head_in_buffer(s, s.top, heads)
        cost +=  has_child_in_buffer(s, s.top, heads)
        if self.allow_reattach and heads[s.top] == s.heads[s.top]:
            cost += 1
        if self.allow_reduce and heads[s.top] == s.second:
            cost += 1
        return cost


cdef transition_to_str(State* s, size_t move, label, object tokens):
    tokens = tokens + ['<end>']
    if move == SHIFT:
        return u'%s-->%s' % (tokens[s.i], tokens[s.top])
    elif move == REDUCE:
        if s.heads[s.top] == 0:
            return u'%s(%s)!!' % (tokens[s.second], tokens[s.top])
        return u'%s/%s' % (tokens[s.top], tokens[s.second])
    else:
        if move == LEFT:
            head = s.i
            child = s.top
        else:
            head = s.top
            child = s.i if s.i < len(tokens) else 0
        return u'%s(%s)' % (tokens[head], tokens[child])

def print_train_msg(n, n_corr, n_move, n_hit, n_miss, stats):
    pc = lambda a, b: '%.1f' % ((float(a) / (b + 1e-100)) * 100)
    move_acc = pc(n_corr, n_move)
    cache_use = pc(n_hit, n_hit + n_miss + 1e-100)
    msg = "#%d: Moves %d/%d=%s" % (n, n_corr, n_move, move_acc)
    if cache_use != 0:
        msg += '. Cache use %s' % cache_use
    if stats['early'] != 0:
        msg += '. Early %s' % pc(stats['early'], stats['sents'])
    if 'moves' in stats:
        msg += '. %.2f moves per sentence' % (float(stats['moves']) / stats['sents'])
    print msg

