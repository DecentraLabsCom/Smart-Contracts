// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

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

    uint private constant EMPTY = 0;

    function first(Tree storage self) internal view returns (uint _key) {
        _key = self.root;
        if (_key != EMPTY) {
            while (self.nodes[_key].left != EMPTY) {
                _key = self.nodes[_key].left;
            }
        }
    }

    function last(Tree storage self) internal view returns (uint _key) {
        _key = self.root;
        if (_key != EMPTY) {
            while (self.nodes[_key].right != EMPTY) {
                _key = self.nodes[_key].right;
            }
        }
    }

    function next(Tree storage self, uint target) internal view returns (uint cursor) {
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

    function prev(Tree storage self, uint target) internal view returns (uint cursor) {
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
    
    function exists(Tree storage self, uint key) internal view returns (bool) {
        return (key != EMPTY) && ((key == self.root) || (self.nodes[key].parent != EMPTY));
    }

    function isEmpty(uint key) internal pure returns (bool) {
        return key == EMPTY;
    }

    function getEmpty() internal pure returns (uint) {
        return EMPTY;
    }

    function getNode(Tree storage self, uint key) public view returns (uint _returnKey, uint _end, uint _parent, uint _left, uint _right, bool _red) {
        require(exists(self, key));
        return(key, self.nodes[key].end, self.nodes[key].parent, self.nodes[key].left, self.nodes[key].right, self.nodes[key].red);
    }

    function findParent(Tree storage self, uint256 key) internal view returns (uint) {
        uint cursor = EMPTY;
        uint probe = self.root;
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

    function overlaps(Tree storage self, uint key, uint end) view internal returns (bool) {
        require(key != EMPTY);
        require(!exists(self, key));
        uint cursor = findParent(self, key);

        // special case for first insert
        if (cursor == EMPTY) {
            return false;
        }

        Node memory referencedNode = self.nodes[cursor];
        // reservation starts before
        if (key < cursor) {
            uint prevCursor = prev(self, cursor);
            uint prevEnd = self.nodes[prevCursor].end;
            return (end > cursor) || (key < prevEnd);
        // reservation starts after
        } else {
            uint nextCursor = prev(self, cursor);
            return (key < referencedNode.end) || ((nextCursor != EMPTY) && (end > nextCursor));
        }
    }

    function insert(Tree storage self, uint32 key, uint32 end) public {
        require(key != EMPTY);
        require(!exists(self, key));
        uint cursor = findParent(self, key);
        Node memory node = Node({parent: cursor, left: EMPTY, right: EMPTY, end: end, red: true});

        // special case for first insert
        if (cursor == EMPTY) {
            self.root = key;
            self.nodes[key] = node;
            insertFixup(self, key);
            return;
        }

        bool overlap;
        if (key < cursor) {
            uint prevCursor = prev(self, cursor);
            overlap = (end > cursor) || ((prevCursor != EMPTY) && (key < self.nodes[prevCursor].end));
            
            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].left = key;
            }
        } else {
            uint nextCursor = next(self, cursor);
            overlap = (key < self.nodes[cursor].end) || ((nextCursor != EMPTY) && (end > nextCursor));
            
            if (!overlap) {
                self.nodes[key] = node;
                self.nodes[cursor].right = key;
            }
        }
        
        if (overlap) {
            revert("Overlap");
        }
        
        insertFixup(self, key);
    }

    function remove(Tree storage self, uint key) internal {
        require(key != EMPTY);
        require(exists(self, key));
        uint probe;
        uint cursor;
        
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
        
        uint yParent = self.nodes[cursor].parent;
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

    function treeMinimum(Tree storage self, uint key) private view returns (uint) {
        while (self.nodes[key].left != EMPTY) {
            key = self.nodes[key].left;
        }
        return key;
    }
    
    function treeMaximum(Tree storage self, uint key) private view returns (uint) {
        while (self.nodes[key].right != EMPTY) {
            key = self.nodes[key].right;
        }
        return key;
    }

    // Unified rotation helper function
    function rotate(Tree storage self, uint key, bool isLeft) private {
        uint cursor;
        uint keyParent = self.nodes[key].parent;
        uint cursorChild;
        
        if (isLeft) {
            cursor = self.nodes[key].right;
            cursorChild = self.nodes[cursor].left;
            self.nodes[key].right = cursorChild;
            self.nodes[cursor].left = key;
        } else {
            cursor = self.nodes[key].left;
            cursorChild = self.nodes[cursor].right;
            self.nodes[key].left = cursorChild;
            self.nodes[cursor].right = key;
        }
        
        if (cursorChild != EMPTY) {
            self.nodes[cursorChild].parent = key;
        }
        
        self.nodes[cursor].parent = keyParent;
        
        if (keyParent == EMPTY) {
            self.root = cursor;
        } else if ((isLeft && key == self.nodes[keyParent].left) || 
                  (!isLeft && key == self.nodes[keyParent].right)) {
            self.nodes[keyParent].left = cursor;
        } else {
            self.nodes[keyParent].right = cursor;
        }
        
        self.nodes[key].parent = cursor;
    }

    function rotateLeft(Tree storage self, uint key) private {
        rotate(self, key, true);
    }
    
    function rotateRight(Tree storage self, uint key) private {
        rotate(self, key, false);
    }

    function insertFixup(Tree storage self, uint key) private {
        uint cursor;
        while (key != self.root && self.nodes[self.nodes[key].parent].red) {
            uint keyParent = self.nodes[key].parent;
            uint keyGrandparent = self.nodes[keyParent].parent;
            bool isLeft = keyParent == self.nodes[keyGrandparent].left;
            
            cursor = isLeft ? self.nodes[keyGrandparent].right : self.nodes[keyGrandparent].left;
            
            if (self.nodes[cursor].red) {
                self.nodes[keyParent].red = false;
                self.nodes[cursor].red = false;
                self.nodes[keyGrandparent].red = true;
                key = keyGrandparent;
            } else {
                if ((isLeft && key == self.nodes[keyParent].right) || 
                    (!isLeft && key == self.nodes[keyParent].left)) {
                    key = keyParent;
                    isLeft ? rotateLeft(self, key) : rotateRight(self, key);
                }
                
                keyParent = self.nodes[key].parent;
                keyGrandparent = self.nodes[keyParent].parent;
                
                self.nodes[keyParent].red = false;
                self.nodes[keyGrandparent].red = true;
                isLeft ? rotateRight(self, keyGrandparent) : rotateLeft(self, keyGrandparent);
            }
        }
        
        self.nodes[self.root].red = false;
    }

    function replaceParent(Tree storage self, uint a, uint b) private {
        uint bParent = self.nodes[b].parent;
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
    
    function removeFixup(Tree storage self, uint key) private {
        uint cursor;
        
        while (key != self.root && !self.nodes[key].red) {
            uint keyParent = self.nodes[key].parent;
            bool isLeft = key == self.nodes[keyParent].left;
            
            cursor = isLeft ? self.nodes[keyParent].right : self.nodes[keyParent].left;
            
            if (self.nodes[cursor].red) {
                self.nodes[cursor].red = false;
                self.nodes[keyParent].red = true;
                isLeft ? rotateLeft(self, keyParent) : rotateRight(self, keyParent);
                cursor = isLeft ? self.nodes[keyParent].right : self.nodes[keyParent].left;
            }
            
            uint cursorLeft = self.nodes[cursor].left;
            uint cursorRight = self.nodes[cursor].right;
            
            if ((!isLeft && !self.nodes[cursorRight].red && !self.nodes[cursorLeft].red) ||
                (isLeft && !self.nodes[cursorLeft].red && !self.nodes[cursorRight].red)) {
                self.nodes[cursor].red = true;
                key = keyParent;
            } else {
                if ((isLeft && !self.nodes[cursorRight].red) || 
                    (!isLeft && !self.nodes[cursorLeft].red)) {
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