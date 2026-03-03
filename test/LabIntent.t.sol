// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/facets/lab/LabAdminFacet.sol";
import "../contracts/facets/lab/LabQueryFacet.sol";
import "../contracts/facets/lab/LabIntentFacet.sol";
import "../contracts/facets/test/TestHelperFacet.sol";
import "../contracts/external/LabERC20.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";
import {ActionIntentPayload} from "../contracts/libraries/IntentTypes.sol";
import {LibIntent} from "../contracts/libraries/LibIntent.sol";

/// @title LabIntent Test
/// @notice Tests LabIntentFacet intent-based lab operations
contract LabIntentTest is BaseTest {
    Diamond diamond;
    LabAdminFacet labAdmin;
    LabFacet labFacet;
    LabQueryFacet labQuery;
    LabIntentFacet labIntent;
    ProviderFacet providerFacet;
    TestHelperFacet testHelper;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);

    uint8 constant ACTION_LAB_ADD = 1;
    uint8 constant ACTION_LAB_ADD_AND_LIST = 2;
    uint8 constant ACTION_LAB_SET_URI = 3;
    uint8 constant ACTION_LAB_UPDATE = 4;
    uint8 constant ACTION_LAB_DELETE = 5;
    uint8 constant ACTION_LAB_LIST = 6;
    uint8 constant ACTION_LAB_UNLIST = 7;

    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function _makePayload(
        address executor,
        uint256 labId,
        string memory uri,
        uint96 price,
        string memory accessURI,
        string memory accessKey,
        string memory tokenURI_
    ) internal pure returns (ActionIntentPayload memory) {
        return ActionIntentPayload({
            executor: executor,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: labId,
            reservationKey: bytes32(0),
            uri: uri,
            price: price,
            maxBatch: 0,
            accessURI: accessURI,
            accessKey: accessKey,
            tokenURI: tokenURI_,
            resourceType: 0
        });
    }

    function _setPendingIntent(
        bytes32 requestId,
        address executor,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        bytes32 payloadHash = LibIntent.hashActionPayloadPublic(payload);
        testHelper.test_setPendingActionIntent(
            requestId,
            executor, // signer
            executor,
            action,
            payloadHash,
            uint64(block.timestamp),
            uint64(block.timestamp + 3600)
        );
    }

    function setUp() public override {
        super.setUp();

        DiamondCutFacet dc = new DiamondCutFacet();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory dcSelectors = new bytes4[](1);
        dcSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(dc), action: IDiamond.FacetCutAction.Add, functionSelectors: dcSelectors
        });

        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        diamond = new Diamond(cut, args);

        InitFacet initFacet = new InitFacet();
        ProviderFacet providerFacetImpl = new ProviderFacet();
        LabFacet labFacetImpl = new LabFacet();
        LabAdminFacet labAdminImpl = new LabAdminFacet();
        LabQueryFacet labQueryImpl = new LabQueryFacet();
        LabIntentFacet labIntentImpl = new LabIntentFacet();
        TestHelperFacet testHelperImpl = new TestHelperFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](7);

        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,address,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](3);
        providerSelectors[0] = _selector("initialize(string,string,string,address)");
        providerSelectors[1] = _selector("addProvider(string,address,string,string,string)");
        providerSelectors[2] = _selector("isLabProvider(address)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: providerSelectors
        });

        bytes4[] memory labSelectors = new bytes4[](6);
        labSelectors[0] = _selector("initialize(string,string)");
        labSelectors[1] = _selector("safeMintTo(address,uint256)");
        labSelectors[2] = _selector("burnToken(uint256)");
        labSelectors[3] = _selector("ownerOf(uint256)");
        labSelectors[4] = _selector("tokenURI(uint256)");
        labSelectors[5] = _selector("calculateRequiredStake(address,uint256)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        bytes4[] memory labAdminSelectors = new bytes4[](6);
        labAdminSelectors[0] = _selector("addLab(string,uint96,string,string,uint8)");
        labAdminSelectors[1] = _selector("updateLab(uint256,string,uint96,string,string,uint8)");
        labAdminSelectors[2] = _selector("setTokenURI(uint256,string)");
        labAdminSelectors[3] = _selector("deleteLab(uint256)");
        labAdminSelectors[4] = _selector("listLab(uint256)");
        labAdminSelectors[5] = _selector("unlistLab(uint256)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labAdminImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labAdminSelectors
        });

        bytes4[] memory labQuerySelectors = new bytes4[](3);
        labQuerySelectors[0] = _selector("getLab(uint256)");
        labQuerySelectors[1] = _selector("isLabListed(uint256)");
        labQuerySelectors[2] = _selector("getLabsPaginated(uint256,uint256)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(labQueryImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labQuerySelectors
        });

        bytes4[] memory labIntentSelectors = new bytes4[](7);
        labIntentSelectors[0] = _selector(
            "addLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[1] = _selector(
            "addAndListLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[2] = _selector(
            "updateLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[3] = _selector(
            "deleteLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[4] = _selector(
            "setTokenURIWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[5] = _selector(
            "listLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        labIntentSelectors[6] = _selector(
            "unlistLabWithIntent(bytes32,(address,string,string,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        cut2[5] = IDiamond.FacetCut({
            facetAddress: address(labIntentImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labIntentSelectors
        });

        bytes4[] memory testHelperSelectors = new bytes4[](1);
        testHelperSelectors[0] =
            _selector("test_setPendingActionIntent(bytes32,address,address,uint8,bytes32,uint64,uint64)");
        cut2[6] = IDiamond.FacetCut({
            facetAddress: address(testHelperImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: testHelperSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        token = new LabERC20();
        token.initialize("LS", address(diamond));

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", address(token), "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        labFacet = LabFacet(address(diamond));
        labAdmin = LabAdminFacet(address(diamond));
        labQuery = LabQueryFacet(address(diamond));
        labIntent = LabIntentFacet(address(diamond));
        testHelper = TestHelperFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");
        vm.prank(admin);
        providerFacet.addProvider("Provider2", provider2, "p2@x", "ES", "");
    }

    function test_addLabWithIntent_creates_lab() public {
        bytes32 requestId = keccak256("add-lab-1");
        ActionIntentPayload memory payload =
            _makePayload(provider1, 0, "ipfs://intent-lab", 100 ether, "https://access.example.com", "key1", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_ADD, payload);

        vm.prank(provider1);
        labIntent.addLabWithIntent(requestId, payload);

        assertEq(labFacet.ownerOf(1), provider1);
        assertEq(labFacet.tokenURI(1), "ipfs://intent-lab");
        assertEq(labQuery.getLab(1).base.price, 100 ether);
    }

    function test_addLabWithIntent_requires_provider_role() public {
        address nonProvider = address(0xBAD);
        bytes32 requestId = keccak256("add-lab-bad");
        ActionIntentPayload memory payload = _makePayload(nonProvider, 0, "ipfs://x", 10 ether, "a", "k", "");
        _setPendingIntent(requestId, nonProvider, ACTION_LAB_ADD, payload);

        vm.prank(nonProvider);
        vm.expectRevert();
        labIntent.addLabWithIntent(requestId, payload);
    }

    function test_addLabWithIntent_reverts_when_labId_nonzero() public {
        bytes32 requestId = keccak256("add-lab-bad-id");
        ActionIntentPayload memory payload = _makePayload(provider1, 1, "ipfs://x", 10 ether, "a", "k", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_ADD, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_ADD: labId must be 0");
        labIntent.addLabWithIntent(requestId, payload);
    }

    function test_addAndListLabWithIntent_succeeds_and_lists_lab() public {
        bytes32 requestId = keccak256("add-list-1");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "ipfs://add-list", 10 ether, "a", "k", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_ADD_AND_LIST, payload);

        vm.prank(provider1);
        labIntent.addAndListLabWithIntent(requestId, payload);

        assertEq(labFacet.ownerOf(1), provider1);
        assertTrue(labQuery.isLabListed(1));
    }

    function test_updateLabWithIntent_updates_metadata() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://original", 50 ether, "https://old", "key-old", 0);

        bytes32 requestId = keccak256("update-1");
        ActionIntentPayload memory payload =
            _makePayload(provider1, 1, "ipfs://updated", 200 ether, "https://new", "key-new", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_UPDATE, payload);

        vm.prank(provider1);
        labIntent.updateLabWithIntent(requestId, payload);

        assertEq(labFacet.tokenURI(1), "ipfs://updated");
        assertEq(labQuery.getLab(1).base.price, 200 ether);
    }

    function test_updateLabWithIntent_reverts_when_labId_zero() public {
        bytes32 requestId = keccak256("update-bad");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "ipfs://x", 10 ether, "a", "k", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_UPDATE, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_UPDATE: labId required");
        labIntent.updateLabWithIntent(requestId, payload);
    }

    function test_deleteLabWithIntent_burns_lab() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://to-delete", 10 ether, "a", "k", 0);

        bytes32 requestId = keccak256("delete-1");
        ActionIntentPayload memory payload = _makePayload(provider1, 1, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_DELETE, payload);

        vm.prank(provider1);
        labIntent.deleteLabWithIntent(requestId, payload);

        vm.expectRevert();
        labFacet.ownerOf(1);
    }

    function test_deleteLabWithIntent_reverts_when_labId_zero() public {
        bytes32 requestId = keccak256("delete-bad");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_DELETE, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_DELETE: labId required");
        labIntent.deleteLabWithIntent(requestId, payload);
    }

    function test_setTokenURIWithIntent_updates_uri() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://original", 10 ether, "a", "k", 0);

        bytes32 requestId = keccak256("set-uri-1");
        ActionIntentPayload memory payload = _makePayload(provider1, 1, "", 0, "", "", "ipfs://new-token-uri");
        _setPendingIntent(requestId, provider1, ACTION_LAB_SET_URI, payload);

        vm.prank(provider1);
        labIntent.setTokenURIWithIntent(requestId, payload);

        assertEq(labFacet.tokenURI(1), "ipfs://new-token-uri");
    }

    function test_setTokenURIWithIntent_reverts_when_labId_zero() public {
        bytes32 requestId = keccak256("set-uri-bad");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "", 0, "", "", "ipfs://x");
        _setPendingIntent(requestId, provider1, ACTION_LAB_SET_URI, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_SET_URI: labId required");
        labIntent.setTokenURIWithIntent(requestId, payload);
    }

    function test_listLabWithIntent_lists_lab() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab", 10 ether, "a", "k", 0);
        assertFalse(labQuery.isLabListed(1));

        bytes32 requestId = keccak256("list-1");
        ActionIntentPayload memory payload = _makePayload(provider1, 1, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_LIST, payload);

        vm.prank(provider1);
        labIntent.listLabWithIntent(requestId, payload);

        assertTrue(labQuery.isLabListed(1));
    }

    function test_listLabWithIntent_reverts_when_labId_zero() public {
        bytes32 requestId = keccak256("list-bad");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_LIST, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_LIST: labId required");
        labIntent.listLabWithIntent(requestId, payload);
    }

    function test_unlistLabWithIntent_unlists_lab() public {
        vm.startPrank(provider1);
        labAdmin.addLab("ipfs://lab", 10 ether, "a", "k", 0);
        labAdmin.listLab(1);
        vm.stopPrank();
        assertTrue(labQuery.isLabListed(1));

        bytes32 requestId = keccak256("unlist-1");
        ActionIntentPayload memory payload = _makePayload(provider1, 1, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_UNLIST, payload);

        vm.prank(provider1);
        labIntent.unlistLabWithIntent(requestId, payload);

        assertFalse(labQuery.isLabListed(1));
    }

    function test_unlistLabWithIntent_reverts_when_labId_zero() public {
        bytes32 requestId = keccak256("unlist-bad");
        ActionIntentPayload memory payload = _makePayload(provider1, 0, "", 0, "", "", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_UNLIST, payload);

        vm.prank(provider1);
        vm.expectRevert("LAB_UNLIST: labId required");
        labIntent.unlistLabWithIntent(requestId, payload);
    }

    function test_consumeIntent_requires_executor_as_caller() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab", 10 ether, "a", "k", 0);

        bytes32 requestId = keccak256("update-wrong-caller");
        ActionIntentPayload memory payload =
            _makePayload(provider1, 1, "ipfs://updated", 200 ether, "https://new", "key-new", "");
        _setPendingIntent(requestId, provider1, ACTION_LAB_UPDATE, payload);

        vm.prank(provider2);
        vm.expectRevert();
        labIntent.updateLabWithIntent(requestId, payload);
    }
}
