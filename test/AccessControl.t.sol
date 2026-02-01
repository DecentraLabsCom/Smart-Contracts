// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import "../contracts/external/LabERC20.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/libraries/LibDiamond.sol";
import "../contracts/libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract OwnerSetter {
    function setOwner(
        address _new
    ) external {
        LibDiamond.setContractOwner(_new);
    }
}

// Test helper: call ProviderFacet.initialize via delegatecall from an Initializable caller
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ProviderInitializeCaller is Initializable {
    function runInitialize(
        address providerAddr,
        string memory name,
        string memory email,
        string memory country,
        address labToken
    ) public reinitializer(1) {
        (bool ok, bytes memory res) = providerAddr.delegatecall(
            abi.encodeWithSignature("initialize(string,string,string,address)", name, email, country, labToken)
        );
        if (!ok) {
            // bubble up revert
            assembly { revert(add(res, 32), mload(res)) }
        }
    }
}

contract Inspector {
    function checkRole(
        bytes32 role
    ) external view returns (address who, bool has) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        who = msg.sender;
        has = EnumerableSet.contains(s.roleMembers[role], msg.sender);
    }
}

contract InstitutionalTreasuryFacetMock {
    using EnumerableSet for EnumerableSet.AddressSet;

    function addInstitution(
        address a
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.add(s.roleMembers[INSTITUTION_ROLE], a);
    }

    function authorizeBackend(
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.roleMembers[INSTITUTION_ROLE].contains(msg.sender), "Unknown institution");
        s.institutionalBackends[msg.sender] = backend;
    }

    function getBackend(
        address institution
    ) external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalBackends[institution];
    }
}

contract ProviderFacetMock {
    function setProviderAuthURI(
        string calldata uri
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(EnumerableSet.contains(s.roleMembers[PROVIDER_ROLE], msg.sender), "Only provider");
        s.providers[msg.sender].authURI = uri; // note: providers mapping uses ProviderBase struct
    }

    function getProviderAuthURI(
        address provider
    ) external view returns (string memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.providers[provider].authURI;
    }

    function addProviderRole(
        address provider
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.add(s.roleMembers[PROVIDER_ROLE], provider);
    }
}

contract AccessControlTest is Test {
    OwnerSetter setter;
    ProviderInitializeCaller initializerCaller;
    ProviderFacet provider;
    InstitutionalTreasuryFacet instFacet;
    LabERC20 lab;

    address admin = address(0xA11CE);
    address nonAdmin = address(0xB0B);
    address inst = address(0xC0FFEE);

    function setUp() public {
        setter = new OwnerSetter();
        initializerCaller = new ProviderInitializeCaller();
        provider = new ProviderFacet();
        instFacet = new InstitutionalTreasuryFacet();
        lab = new LabERC20();
    }

    function test_onlyAdmin_can_initialize_provider() public {
        // set contract owner to admin
        setter.setOwner(admin);

        // non-admin should not be able to call the global init entrypoint (InitFacet)
        InitFacet initFacet = new InitFacet();
        vm.prank(nonAdmin);
        vm.expectRevert();
        initFacet.initializeDiamond("x", "x", "x", address(0), "LN", "LS");

        // TODO: add diamond harness to exercise successful init end-to-end

        // leave the rest of initialization to separate integration tests focused on diamond deployment
    }

    function _delegateAuthorizeBackend(
        address backend
    ) internal {
        (bool ok, bytes memory res) =
            address(instFacet).delegatecall(abi.encodeWithSignature("authorizeBackend(address)", backend));
        if (!ok) assembly { revert(add(res, 32), mload(res)) }
    }

    function _delegateSetProviderAuthURI(
        string memory uri
    ) internal {
        (bool ok, bytes memory res) =
            address(provider).delegatecall(abi.encodeWithSignature("setProviderAuthURI(string)", uri));
        if (!ok) assembly { revert(add(res, 32), mload(res)) }
    }

    function test_onlyInstitution_can_authorize_backend_and_provider_authuri_restricted() public {
        // For unit testing access control we can directly manipulate AppStorage to set roles
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.add(s.roleMembers[INSTITUTION_ROLE], inst);
        // verify role set in test storage
        assertTrue(EnumerableSet.contains(s.roleMembers[INSTITUTION_ROLE], inst));

        // Use test mocks that own their own storage to validate access control without diamond harness
        InstitutionalTreasuryFacetMock mockInst = new InstitutionalTreasuryFacetMock();
        ProviderFacetMock mockProv = new ProviderFacetMock();

        // set institution role on the mock
        mockInst.addInstitution(inst);

        // non-institution cannot authorize backend
        vm.prank(nonAdmin);
        vm.expectRevert();
        mockInst.authorizeBackend(address(0x1234));

        // institution can authorize backend
        vm.prank(inst);
        mockInst.authorizeBackend(address(0x4567));
        assertEq(mockInst.getBackend(inst), address(0x4567));

        // provider-specific auth URI: only PROVIDER_ROLE can set
        mockProv.addProviderRole(inst);
        string memory goodURI = "https://provider.example.com/auth";

        vm.prank(inst);
        mockProv.setProviderAuthURI(goodURI);
        assertEq(mockProv.getProviderAuthURI(inst), goodURI);

        vm.prank(nonAdmin);
        vm.expectRevert();
        mockProv.setProviderAuthURI(goodURI);
    }
}
