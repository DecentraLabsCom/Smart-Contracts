// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/libraries/LibDiamond.sol";
import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @dev Mock facet for testing initializer allow-list
contract MockFacet {
    // Storage slot for testing - will be written in Diamond's storage
    bytes32 constant MOCK_STORAGE_SLOT = keccak256("mock.facet.storage");

    function initialize() external {
        // Write to diamond's storage
        bytes32 slot = MOCK_STORAGE_SLOT;
        assembly {
            sstore(slot, 1) // Set to true
        }
    }

    function getInitialized() external view returns (bool) {
        bytes32 slot = MOCK_STORAGE_SLOT;
        bool value;
        assembly {
            value := sload(slot)
        }
        return value;
    }
}

/// @dev Mock initializer WITH isInitializer() marker
contract SafeExternalInitializer {
    bytes32 constant SAFE_STORAGE_SLOT = keccak256("safe.initializer.storage");

    function init() external {
        bytes32 slot = SAFE_STORAGE_SLOT;
        assembly {
            sstore(slot, 1)
        }
    }

    function getWasCalled() external view returns (bool) {
        bytes32 slot = SAFE_STORAGE_SLOT;
        bool value;
        assembly {
            value := sload(slot)
        }
        return value;
    }

    /// @notice Marker to be recognized as safe initializer
    function isInitializer() external pure returns (bool) {
        return true;
    }
}

/// @dev Mock initializer WITHOUT isInitializer() marker (unsafe/legacy)
contract UnsafeExternalInitializer {
    bool public wasCalled;

    function init() external {
        wasCalled = true;
    }
}

/// @dev Minimal Diamond wrapper to test LibDiamond.initializeDiamondCut
contract DiamondHarness {
    event InitializationReverted(bytes data);

    constructor() {
        LibDiamond.setContractOwner(msg.sender);
    }

    /// @dev Internal entry used to call the library directly. Kept external so we can capture revert data via a low-level call.
    function _callInitialize(
        address _init,
        bytes calldata _calldata,
        IDiamond.FacetCut[] calldata _diamondCut
    ) external {
        LibDiamond.initializeDiamondCut(_init, _calldata, _diamondCut);
    }

    /// @dev Expose initializeDiamondCut for testing but wrap call to capture revert data
    function callInitializeDiamondCut(
        address _init,
        bytes memory _calldata,
        IDiamond.FacetCut[] memory _diamondCut
    ) external {
        // Perform an external call to our internal entry to capture revert data in the low-level call result
        (bool success, bytes memory data) =
            address(this).call(abi.encodeWithSelector(this._callInitialize.selector, _init, _calldata, _diamondCut));
        if (!success) {
            // Emit the revert data for test harnesses to inspect
            emit InitializationReverted(data);
            // Revert with the original data so existing tests that expect reverts continue to behave the same
            assembly ("memory-safe") {
                let returndata_size := mload(data)
                revert(add(32, data), returndata_size)
            }
        }
    }
}

contract LibDiamondInitializerTest is Test {
    DiamondHarness public diamond;
    MockFacet public mockFacet;
    SafeExternalInitializer public safeInit;
    UnsafeExternalInitializer public unsafeInit;
    FalseMarkerInitializer public falseMarkerInit;

    function setUp() public {
        diamond = new DiamondHarness();
        mockFacet = new MockFacet();
        safeInit = new SafeExternalInitializer();
        unsafeInit = new UnsafeExternalInitializer();
        falseMarkerInit = new FalseMarkerInitializer();
    }

    /// @dev Test 1: Initializer included in the facet cut is allowed (no marker needed)
    function test_initializeDiamondCut_facetInCut_allowed() public {
        // Prepare a cut that includes mockFacet
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockFacet.initialize.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(mockFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });

        // Call initializeDiamondCut with mockFacet as _init (it's in the cut)
        bytes memory initData = abi.encodeWithSelector(MockFacet.initialize.selector);

        diamond.callInitializeDiamondCut(address(mockFacet), initData, cut);

        // Verify initialization executed successfully by reading storage slot directly
        bytes32 storageSlot = keccak256("mock.facet.storage");
        bool initialized = vm.load(address(diamond), storageSlot) != bytes32(0);
        assertTrue(initialized, "MockFacet should be initialized");
    }

    /// @dev Test 2: External initializer WITH isInitializer() marker is allowed
    function test_initializeDiamondCut_withMarker_allowed() public {
        // Prepare an empty cut (initializer is NOT in the cut)
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);

        // Call initializeDiamondCut with safeInit (has isInitializer() marker)
        bytes memory initData = abi.encodeWithSelector(SafeExternalInitializer.init.selector);

        diamond.callInitializeDiamondCut(address(safeInit), initData, cut);

        // Verify initialization executed successfully by reading storage slot directly
        bytes32 storageSlot = keccak256("safe.initializer.storage");
        bool wasCalled = vm.load(address(diamond), storageSlot) != bytes32(0);
        assertTrue(wasCalled, "SafeExternalInitializer should be called");
    }

    /// @dev Test 3: External initializer WITHOUT isInitializer() marker reverts with InitializationNotAllowed
    function test_initializeDiamondCut_withoutMarker_reverts() public {
        // Prepare an empty cut (initializer is NOT in the cut)
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);

        // Call initializeDiamondCut with unsafeInit (NO isInitializer() marker)
        bytes memory initData = abi.encodeWithSelector(UnsafeExternalInitializer.init.selector);

        // Expect revert with InitializationNotAllowed
        vm.expectRevert(abi.encodeWithSelector(InitializationNotAllowed.selector, address(unsafeInit)));
        diamond.callInitializeDiamondCut(address(unsafeInit), initData, cut);

        // Verify initialization was NOT executed
        assertFalse(unsafeInit.wasCalled(), "UnsafeExternalInitializer should NOT be called");
    }

    /// @dev Test 4: Calldata too short (< 4 bytes) reverts with InitializationCalldataTooShort
    function test_initializeDiamondCut_shortCalldata_reverts() public {
        // Prepare an empty cut
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);

        // Prepare calldata with only 3 bytes (invalid selector)
        bytes memory shortCalldata = new bytes(3);

        // Expect revert with InitializationCalldataTooShort
        vm.expectRevert(abi.encodeWithSelector(InitializationCalldataTooShort.selector));
        diamond.callInitializeDiamondCut(address(safeInit), shortCalldata, cut);
    }

    /// @dev Test 5: Empty calldata (0 bytes) reverts with InitializationCalldataTooShort
    function test_initializeDiamondCut_emptyCalldata_reverts() public {
        // Prepare an empty cut
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);

        // Empty calldata
        bytes memory emptyCalldata = "";

        // Expect revert with InitializationCalldataTooShort
        vm.expectRevert(abi.encodeWithSelector(InitializationCalldataTooShort.selector));
        diamond.callInitializeDiamondCut(address(safeInit), emptyCalldata, cut);
    }

    /// @dev Test 6: Zero address initializer is allowed (noop case)
    function test_initializeDiamondCut_zeroAddress_noop() public {
        // Prepare an empty cut
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);

        // Call with zero address (should be noop and not revert)
        bytes memory anyCalldata = abi.encodeWithSelector(bytes4(0x12345678));
        diamond.callInitializeDiamondCut(address(0), anyCalldata, cut);

        // No revert = success (noop path)
    }

    /// @dev Test 7: Initializer that returns false from isInitializer() reverts
    function test_initializeDiamondCut_markerReturnsFalse_reverts() public {
        // Deploy a mock that returns false from isInitializer()
        FalseMarkerInitializer falseMarker = new FalseMarkerInitializer();

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);
        bytes memory initData = abi.encodeWithSelector(FalseMarkerInitializer.init.selector);

        // Expect revert with InitializationNotAllowed
        vm.expectRevert(abi.encodeWithSelector(InitializationNotAllowed.selector, address(falseMarker)));
        diamond.callInitializeDiamondCut(address(falseMarker), initData, cut);
    }

    /// @dev Test 8: Multiple facets in cut, initializer matches one of them
    function test_initializeDiamondCut_multipleFacetsInCut_matchesOne() public {
        MockFacet facet2 = new MockFacet();

        // Prepare a cut with multiple facets
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = MockFacet.initialize.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(mockFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors1
        });

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = bytes4(keccak256("someOtherFunction()"));
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(facet2), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors2
        });

        // Use facet2 as initializer (it's in the cut)
        bytes memory initData = abi.encodeWithSelector(MockFacet.initialize.selector);

        diamond.callInitializeDiamondCut(address(facet2), initData, cut);

        // Should succeed without needing isInitializer() marker
    }
}

/// @dev Mock that implements isInitializer() but returns false
contract FalseMarkerInitializer {
    function init() external {}

    function isInitializer() external pure returns (bool) {
        return false;
    }
}
