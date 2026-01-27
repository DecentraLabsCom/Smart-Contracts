// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

// ----------------------------------------------------------------------------
// Rival Interval Tree Library v1.0-pre-release-a - Optimized for bytecode size
// Adapted from https://github.com/bokkypoobah/BokkyPooBahsRedBlackTreeLibrary
//
// A Solidity Red-Black Tree binary search library to store and access a sorted
// list of rival intervals.  Rival intervals can't overlap
//
// The Red-Black algorithm rebalances the binary
// search tree, resulting in O(log n) insert, remove and search time (and ~gas)
//
// ----------------------------------------------------------------------------

import {Tree, Node} from "./LibAppStorage.sol";

library RivalIntervalTreeLibrary {
    uint256 private constant EMPTY = 0;

    // Test-only tracing events: enabled in test runs to diagnose pathological sequences
    event TraceInsertStep(
        string step, uint256 key, uint256 cursor, uint256 parent, uint256 left, uint256 right, uint256 end, bool red
    );
    event TraceRotation(string step, uint256 key, uint256 cursor, uint256 cursorChild, uint256 parent);
    // Additional rotation post-state for diagnostics (root and parent pointers)
    event TraceRotateState(uint256 root, uint256 key, uint256 cursor, uint256 cursor_parent, uint256 key_parent);
    // Emit black-height checks for quick local diagnostics in tests
    event TraceBHCheck(uint256 node, uint256 hl, uint256 hr, string context);
    bool private constant RIT_TEST_TRACE = true;

    function first(
        Tree storage self
    ) internal view returns (uint256 _key) {
        _key = self.root;
        if (_key != EMPTY) {
            while (self.nodes[_key].left != EMPTY) {
                _key = self.nodes[_key].left;
            }
        }
    }

    function last(
        Tree storage self
    ) internal view returns (uint256 _key) {
        _key = self.root;
        if (_key != EMPTY) {
            while (self.nodes[_key].right != EMPTY) {
                _key = self.nodes[_key].right;
            }
        }
    }

    function next(
        Tree storage self,
        uint256 target
    ) internal view returns (uint256 cursor) {
        require(target != EMPTY);
        if (self.nodes[target].right != EMPTY) {
            cursor = treeMinimum(self, self.nodes[target].right);
        } else {
            cursor = self.nodes[target].parent;
            while (cursor != EMPTY && target == self.nodes[cursor].right) {
                target = cursor;
                cursor = self.nodes[cursor].parent;
            }
        }
    }

    function prev(
        Tree storage self,
        uint256 target
    ) internal view returns (uint256 cursor) {
        require(target != EMPTY);
        if (self.nodes[target].left != EMPTY) {
            cursor = treeMaximum(self, self.nodes[target].left);
        } else {
            cursor = self.nodes[target].parent;
            while (cursor != EMPTY && target == self.nodes[cursor].left) {
                target = cursor;
                cursor = self.nodes[cursor].parent;
            }
        }
    }

    // Removed commented out functions size() and getAllKeys()

    function exists(
        Tree storage self,
        uint256 key
    ) internal view returns (bool) {
        return (key != EMPTY) && ((key == self.root) || (self.nodes[key].parent != EMPTY));
    }

    function isEmpty(
        uint256 key
    ) internal pure returns (bool) {
        return key == EMPTY;
    }

    function getEmpty() internal pure returns (uint256) {
        return EMPTY;
    }

    function getNode(
        Tree storage self,
        uint256 key
    )
        internal
        view
        returns (uint256 _returnKey, uint256 _end, uint256 _parent, uint256 _left, uint256 _right, bool _red)
    {
        require(exists(self, key));
        return (
            key,
            self.nodes[key].end,
            self.nodes[key].parent,
            self.nodes[key].left,
            self.nodes[key].right,
            self.nodes[key].red
        );
    }

    function findParent(
        Tree storage self,
        uint256 key
    ) internal view returns (uint256) {
        uint256 cursor = EMPTY;
        uint256 probe = self.root;
        while (probe != EMPTY) {
            cursor = probe;
            if (key < probe) {
                probe = self.nodes[probe].left;
            } else {
                probe = self.nodes[probe].right;
            }
        }
        return cursor;
    }

    /// @notice Check if a time interval conflicts with existing reservations (safe version for queries)
    /// @dev Similar to overlaps() but returns true for existing keys instead of reverting
    ///      This is the correct function to use for availability checks
    /// @param self The tree storage reference
    /// @param key The start time of the interval to check
    /// @param end The end time of the interval to check
    /// @return bool True if there is a conflict (overlaps or key exists), False if available
    function hasConflict(
        Tree storage self,
        uint256 key,
        uint256 end
    ) internal view returns (bool) {
        if (key == EMPTY) return true;

        // CRITICAL FIX: If key already exists, it's definitely a conflict
        if (exists(self, key)) return true;

        uint256 cursor = findParent(self, key);

        // special case for first insert
        if (cursor == EMPTY) {
            return false;
        }

        Node memory referencedNode = self.nodes[cursor];
        // reservation starts before
        if (key < cursor) {
            uint256 prevCursor = prev(self, cursor);
            uint256 prevEnd = self.nodes[prevCursor].end;
            return (end > cursor) || (key < prevEnd);
            // reservation starts after
        } else {
            uint256 nextCursor = next(self, cursor);
            return (key < referencedNode.end) || ((nextCursor != EMPTY) && (end > nextCursor));
        }
    }

    function overlaps(
        Tree storage self,
        uint256 key,
        uint256 end
    ) internal view returns (bool) {
        require(key != EMPTY);
        require(!exists(self, key));
        uint256 cursor = findParent(self, key);

        // special case for first insert
        if (cursor == EMPTY) {
            return false;
        }

        Node memory referencedNode = self.nodes[cursor];
        // reservation starts before
        if (key < cursor) {
            uint256 prevCursor = prev(self, cursor);
            uint256 prevEnd = self.nodes[prevCursor].end;
            return (end > cursor) || (key < prevEnd);
            // reservation starts after
        } else {
            uint256 nextCursor = next(self, cursor); // FIX: Changed from prev() to next()
            return (key < referencedNode.end) || ((nextCursor != EMPTY) && (end > nextCursor));
        }
    }

    function insert(
        Tree storage self,
        uint32 key,
        uint32 end
    ) internal {
        require(key != EMPTY);
        require(!exists(self, key));
        uint256 cursor = findParent(self, key);
        Node memory node = Node({parent: cursor, left: EMPTY, right: EMPTY, end: end, red: true});
        if (RIT_TEST_TRACE && self.debug) {
            emit TraceInsertStep("findParent", key, cursor, node.parent, 0, 0, node.end, node.red);
        }

        // special case for first insert
        if (cursor == EMPTY) {
            self.root = key;
            self.nodes[key] = node;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "first_insert", key, cursor, node.parent, node.left, node.right, node.end, node.red
                );
            }
            insertFixup(self, key);
            return;
        }

        bool overlap;
        if (key < cursor) {
            uint256 prevCursor = prev(self, cursor);
            overlap = (end > cursor) || ((prevCursor != EMPTY) && (key < self.nodes[prevCursor].end));
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "overlap_check_left",
                    key,
                    cursor,
                    node.parent,
                    self.nodes[cursor].left,
                    self.nodes[cursor].right,
                    node.end,
                    node.red
                );
            }

            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].left = key;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertStep(
                        "linked_left", key, cursor, node.parent, node.left, node.right, node.end, node.red
                    );
                }
            }
        } else {
            uint256 nextCursor = next(self, cursor);
            overlap = (key < self.nodes[cursor].end) || ((nextCursor != EMPTY) && (end > nextCursor));
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "overlap_check_right",
                    key,
                    cursor,
                    node.parent,
                    self.nodes[cursor].left,
                    self.nodes[cursor].right,
                    node.end,
                    node.red
                );
            }

            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].right = key;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertStep(
                        "linked_right", key, cursor, node.parent, node.left, node.right, node.end, node.red
                    );
                }
            }
        }

        if (overlap) {
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep("overlap_detected", key, cursor, node.parent, 0, 0, node.end, node.red);
            }
            revert("Overlap");
        }

        insertFixup(self, key);
    }

    /// @notice Test-only insert that emits trace events but does not revert on overlap
    /// @dev Returns true if insertion succeeded, false on overlap or invalid key
    function tryInsert(
        Tree storage self,
        uint32 key,
        uint32 end
    ) internal returns (bool) {
        if (key == EMPTY) return false;
        if (exists(self, key)) return false;

        uint256 cursor = findParent(self, key);
        Node memory node = Node({parent: cursor, left: EMPTY, right: EMPTY, end: end, red: true});
        if (RIT_TEST_TRACE && self.debug) {
            emit TraceInsertStep("findParent", key, cursor, node.parent, 0, 0, node.end, node.red);
        }

        // special case for first insert
        if (cursor == EMPTY) {
            self.root = key;
            self.nodes[key] = node;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "first_insert", key, cursor, node.parent, node.left, node.right, node.end, node.red
                );
            }
            insertFixup(self, key);
            return true;
        }

        bool overlap;
        if (key < cursor) {
            uint256 prevCursor = prev(self, cursor);
            overlap = (end > cursor) || ((prevCursor != EMPTY) && (key < self.nodes[prevCursor].end));
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "overlap_check_left",
                    key,
                    cursor,
                    node.parent,
                    self.nodes[cursor].left,
                    self.nodes[cursor].right,
                    node.end,
                    node.red
                );
            }

            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].left = key;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertStep(
                        "linked_left", key, cursor, node.parent, node.left, node.right, node.end, node.red
                    );
                }
            }
        } else {
            uint256 nextCursor = next(self, cursor);
            overlap = (key < self.nodes[cursor].end) || ((nextCursor != EMPTY) && (end > nextCursor));
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep(
                    "overlap_check_right",
                    key,
                    cursor,
                    node.parent,
                    self.nodes[cursor].left,
                    self.nodes[cursor].right,
                    node.end,
                    node.red
                );
            }

            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].right = key;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertStep(
                        "linked_right", key, cursor, node.parent, node.left, node.right, node.end, node.red
                    );
                }
            }
        }

        if (overlap) {
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertStep("overlap_detected", key, cursor, node.parent, 0, 0, node.end, node.red);
            }
            return false;
        }

        insertFixup(self, key);
        return true;
    }

    function remove(
        Tree storage self,
        uint256 key
    ) internal {
        require(key != EMPTY);
        require(exists(self, key));
        uint256 probe;
        uint256 cursor;

        if (self.nodes[key].left == EMPTY || self.nodes[key].right == EMPTY) {
            cursor = key;
        } else {
            cursor = self.nodes[key].right;
            while (self.nodes[cursor].left != EMPTY) {
                cursor = self.nodes[cursor].left;
            }
        }

        if (self.nodes[cursor].left != EMPTY) {
            probe = self.nodes[cursor].left;
        } else {
            probe = self.nodes[cursor].right;
        }

        uint256 yParent = self.nodes[cursor].parent;
        self.nodes[probe].parent = yParent;

        if (yParent != EMPTY) {
            if (cursor == self.nodes[yParent].left) {
                self.nodes[yParent].left = probe;
            } else {
                self.nodes[yParent].right = probe;
            }
        } else {
            self.root = probe;
        }

        bool doFixup = !self.nodes[cursor].red;

        if (cursor != key) {
            replaceParent(self, cursor, key);
            self.nodes[cursor].left = self.nodes[key].left;
            self.nodes[self.nodes[cursor].left].parent = cursor;
            self.nodes[cursor].right = self.nodes[key].right;
            self.nodes[self.nodes[cursor].right].parent = cursor;
            self.nodes[cursor].red = self.nodes[key].red;
            (cursor, key) = (key, cursor);
        }

        if (doFixup) {
            removeFixup(self, probe);
        }

        delete self.nodes[cursor];
    }

    function treeMinimum(
        Tree storage self,
        uint256 key
    ) private view returns (uint256) {
        while (self.nodes[key].left != EMPTY) {
            key = self.nodes[key].left;
        }
        return key;
    }

    function treeMaximum(
        Tree storage self,
        uint256 key
    ) private view returns (uint256) {
        while (self.nodes[key].right != EMPTY) {
            key = self.nodes[key].right;
        }
        return key;
    }

    // Unified rotation helper function
    function rotate(
        Tree storage self,
        uint256 key,
        bool isLeft
    ) private {
        uint256 cursor;
        uint256 keyParent = self.nodes[key].parent;
        uint256 cursorChild;

        if (isLeft) {
            cursor = self.nodes[key].right;
            cursorChild = self.nodes[cursor].left;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceRotation("rotate_left_prepare", key, cursor, cursorChild, keyParent);
            }
            self.nodes[key].right = cursorChild;
            self.nodes[cursor].left = key;
        } else {
            cursor = self.nodes[key].left;
            cursorChild = self.nodes[cursor].right;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceRotation("rotate_right_prepare", key, cursor, cursorChild, keyParent);
            }
            self.nodes[key].left = cursorChild;
            self.nodes[cursor].right = key;
        }

        if (cursorChild != EMPTY) {
            self.nodes[cursorChild].parent = key;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceRotation("rotate_child_relinked", key, cursor, cursorChild, keyParent);
            }
        }

        self.nodes[cursor].parent = keyParent;

        if (keyParent == EMPTY) {
            self.root = cursor;
            if (RIT_TEST_TRACE && self.debug) {
                emit TraceRotation("rotate_new_root", key, cursor, cursorChild, keyParent);
            }
        } else {
            // Link the rotated subtree to the correct side of keyParent based on where `key` was
            if (key == self.nodes[keyParent].left) {
                self.nodes[keyParent].left = cursor;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceRotation("rotate_linked_left", key, cursor, cursorChild, keyParent);
                }
            } else {
                self.nodes[keyParent].right = cursor;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceRotation("rotate_linked_right", key, cursor, cursorChild, keyParent);
                }
            }
        }

        self.nodes[key].parent = cursor;
        if (RIT_TEST_TRACE && self.debug) emit TraceRotation("rotate_complete", key, cursor, cursorChild, keyParent);

        // Test-only consistency checks to catch root/parent pointer inconsistencies early
        if (RIT_TEST_TRACE && self.debug) {
            // cursor.parent should equal keyParent
            require(self.nodes[cursor].parent == keyParent, "rotate:cursor_parent_mismatch");
            // key.parent should equal cursor
            require(self.nodes[key].parent == cursor, "rotate:key_parent_mismatch");
            // If cursor is root, its parent must be EMPTY
            if (self.root == cursor) {
                require(self.nodes[cursor].parent == EMPTY, "rotate:root_has_parent");
            }
            // The root's parent must always be EMPTY
            if (self.root != EMPTY) {
                require(self.nodes[self.root].parent == EMPTY, "rotate:root_parent_nonzero");
            }
            emit TraceRotateState(self.root, key, cursor, self.nodes[cursor].parent, self.nodes[key].parent);

            // Test-only: check black-height equality for the rotated subtree root (cursor)
            {
                (uint256 hl, bool okl) = _blackHeight(self, self.nodes[cursor].left);
                (uint256 hr, bool okr) = _blackHeight(self, self.nodes[cursor].right);
                emit TraceBHCheck(cursor, hl, hr, "post_rotate");
                require(okl && okr && hl == hr, "rotate:bh_mismatch");
            }

            // Also check the parent of the rotated subtree (if any) to catch propagated BH mismatches
            if (keyParent != EMPTY) {
                (uint256 phl, bool pokl) = _blackHeight(self, self.nodes[keyParent].left);
                (uint256 phr, bool pokr) = _blackHeight(self, self.nodes[keyParent].right);
                emit TraceBHCheck(keyParent, phl, phr, "parent_post_rotate");
                require(pokl && pokr && phl == phr, "rotate:parent_bh_mismatch");
            }
        }
    }

    function _blackHeight(
        Tree storage self,
        uint256 k
    ) private view returns (uint256, bool) {
        if (k == EMPTY) return (0, true);
        uint256 left = self.nodes[k].left;
        uint256 right = self.nodes[k].right;
        (uint256 hl, bool ol) = _blackHeight(self, left);
        (uint256 hr, bool orr) = _blackHeight(self, right);
        if (!ol || !orr) return (0, false);
        if (hl != hr) return (0, false);
        uint256 add = self.nodes[k].red ? 0 : 1;
        return (hl + add, true);
    }

    function rotateLeft(
        Tree storage self,
        uint256 key
    ) private {
        rotate(self, key, true);
    }

    function rotateRight(
        Tree storage self,
        uint256 key
    ) private {
        rotate(self, key, false);
    }

    event TraceInsertFixup(
        string step, uint256 key, uint256 keyParent, uint256 keyGrandparent, uint256 cursor, uint256 root, bool rootRed
    );

    function insertFixup(
        Tree storage self,
        uint256 key
    ) private {
        uint256 cursor;
        while (key != self.root && self.nodes[self.nodes[key].parent].red) {
            uint256 keyParent = self.nodes[key].parent;
            uint256 keyGrandparent = self.nodes[keyParent].parent;
            bool isLeft = keyParent == self.nodes[keyGrandparent].left;

            cursor = isLeft ? self.nodes[keyGrandparent].right : self.nodes[keyGrandparent].left;

            if (RIT_TEST_TRACE && self.debug) {
                emit TraceInsertFixup(
                    "loop_start",
                    key,
                    keyParent,
                    keyGrandparent,
                    cursor,
                    self.root,
                    (self.root != EMPTY ? self.nodes[self.root].red : false)
                );
            }

            if (self.nodes[cursor].red) {
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertFixup(
                        "case_both_red",
                        key,
                        keyParent,
                        keyGrandparent,
                        cursor,
                        self.root,
                        (self.root != EMPTY ? self.nodes[self.root].red : false)
                    );
                }
                self.nodes[keyParent].red = false;
                self.nodes[cursor].red = false;
                self.nodes[keyGrandparent].red = true;
                key = keyGrandparent;
            } else {
                if ((isLeft && key == self.nodes[keyParent].right) || (!isLeft && key == self.nodes[keyParent].left)) {
                    if (RIT_TEST_TRACE && self.debug) {
                        emit TraceInsertFixup(
                            "pre_rotate_key",
                            key,
                            keyParent,
                            keyGrandparent,
                            cursor,
                            self.root,
                            (self.root != EMPTY ? self.nodes[self.root].red : false)
                        );
                    }
                    key = keyParent;
                    isLeft ? rotateLeft(self, key) : rotateRight(self, key);
                    if (RIT_TEST_TRACE && self.debug) {
                        emit TraceInsertFixup(
                            "post_rotate_key",
                            key,
                            keyParent,
                            keyGrandparent,
                            cursor,
                            self.root,
                            (self.root != EMPTY ? self.nodes[self.root].red : false)
                        );
                    }
                }

                keyParent = self.nodes[key].parent;
                keyGrandparent = self.nodes[keyParent].parent;

                self.nodes[keyParent].red = false;
                self.nodes[keyGrandparent].red = true;
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertFixup(
                        "pre_rotate_grandparent",
                        key,
                        keyParent,
                        keyGrandparent,
                        cursor,
                        self.root,
                        (self.root != EMPTY ? self.nodes[self.root].red : false)
                    );
                }
                isLeft ? rotateRight(self, keyGrandparent) : rotateLeft(self, keyGrandparent);
                if (RIT_TEST_TRACE && self.debug) {
                    emit TraceInsertFixup(
                        "post_rotate_grandparent",
                        key,
                        keyParent,
                        keyGrandparent,
                        cursor,
                        self.root,
                        (self.root != EMPTY ? self.nodes[self.root].red : false)
                    );
                }

                // Test-only: ensure black heights of grandparent's children are equal after rotation
                if (RIT_TEST_TRACE && self.debug) {
                    (uint256 hl, bool okl) = _blackHeight(self, self.nodes[keyGrandparent].left);
                    (uint256 hr, bool okr) = _blackHeight(self, self.nodes[keyGrandparent].right);
                    emit TraceBHCheck(keyGrandparent, hl, hr, "post_rotate_grandparent");
                    require(okl && okr && hl == hr, "insertFixup:bh_mismatch");
                }
            }
        }

        if (RIT_TEST_TRACE && self.debug) {
            emit TraceInsertFixup(
                "final_root", 0, 0, 0, 0, self.root, (self.root != EMPTY ? self.nodes[self.root].red : false)
            );
        }
        self.nodes[self.root].red = false;
    }

    function replaceParent(
        Tree storage self,
        uint256 a,
        uint256 b
    ) private {
        uint256 bParent = self.nodes[b].parent;
        self.nodes[a].parent = bParent;

        if (bParent == EMPTY) {
            self.root = a;
        } else {
            if (b == self.nodes[bParent].left) {
                self.nodes[bParent].left = a;
            } else {
                self.nodes[bParent].right = a;
            }
        }
    }

    function removeFixup(
        Tree storage self,
        uint256 key
    ) private {
        uint256 cursor;

        while (key != self.root && !self.nodes[key].red) {
            uint256 keyParent = self.nodes[key].parent;
            bool isLeft = key == self.nodes[keyParent].left;

            cursor = isLeft ? self.nodes[keyParent].right : self.nodes[keyParent].left;

            if (self.nodes[cursor].red) {
                self.nodes[cursor].red = false;
                self.nodes[keyParent].red = true;
                isLeft ? rotateLeft(self, keyParent) : rotateRight(self, keyParent);
                cursor = isLeft ? self.nodes[keyParent].right : self.nodes[keyParent].left;
            }

            uint256 cursorLeft = self.nodes[cursor].left;
            uint256 cursorRight = self.nodes[cursor].right;

            if (
                (!isLeft && !self.nodes[cursorRight].red && !self.nodes[cursorLeft].red)
                    || (isLeft && !self.nodes[cursorLeft].red && !self.nodes[cursorRight].red)
            ) {
                self.nodes[cursor].red = true;
                key = keyParent;
            } else {
                if ((isLeft && !self.nodes[cursorRight].red) || (!isLeft && !self.nodes[cursorLeft].red)) {
                    if (isLeft) {
                        self.nodes[cursorLeft].red = false;
                    } else {
                        self.nodes[cursorRight].red = false;
                    }

                    self.nodes[cursor].red = true;
                    isLeft ? rotateRight(self, cursor) : rotateLeft(self, cursor);
                    cursor = isLeft ? self.nodes[keyParent].right : self.nodes[keyParent].left;
                }

                self.nodes[cursor].red = self.nodes[keyParent].red;
                self.nodes[keyParent].red = false;

                if (isLeft) {
                    self.nodes[self.nodes[cursor].right].red = false;
                    rotateLeft(self, keyParent);
                } else {
                    self.nodes[self.nodes[cursor].left].red = false;
                    rotateRight(self, keyParent);
                }

                key = self.root;
            }
        }

        self.nodes[key].red = false;
    }
}
