// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Reservation, INSTITUTION_ROLE, LibAppStorage} from "../../../libraries/LibAppStorage.sol";

/// @title InstitutionalReservationQueryFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract for querying institutional reservation data.
/// @notice Split from InstitutionalReservationFacet to reduce contract size.
/// Provides read-only functions for institutional users to query their reservations.

contract InstitutionalReservationQueryFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Reservation status constants
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    modifier onlyInstitution(
        address institution
    ) {
        _onlyInstitution(institution);
        _;
    }

    function _onlyInstitution(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), "Unknown institution");
        address backend = s.institutionalBackends[institution];
        require(
            msg.sender == institution || (backend != address(0) && msg.sender == backend), "Not authorized institution"
        );
    }

    function _trackingKeyFromInstitutionHash(
        address institution,
        bytes32 pucHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(institution, pucHash)))));
    }

    /// @notice Get the count of reservations for an institutional user
    /// @param institutionalProvider The institution address
    /// @param puc The user's unique identifier within the institution
    /// @return The total count of reservations for this user
    function getInstitutionalUserReservationCount(
        address institutionalProvider,
        string calldata puc
    ) external view onlyInstitution(institutionalProvider) returns (uint256) {
        AppStorage storage s = _s();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        return s.renters[hashKey].length();
    }

    /// @notice Get a reservation key by index for an institutional user
    /// @dev Order is NOT guaranteed stable across mutations. Use for snapshot iteration only.
    /// @param institutionalProvider The institution address
    /// @param puc The user's unique identifier within the institution
    /// @param index The index in the user's reservation list
    /// @return key The reservation key at the given index
    function getInstitutionalUserReservationByIndex(
        address institutionalProvider,
        string calldata puc,
        uint256 index
    ) external view onlyInstitution(institutionalProvider) returns (bytes32 key) {
        AppStorage storage s = _s();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        EnumerableSet.Bytes32Set storage hashReservations = s.renters[hashKey];
        require(index < hashReservations.length(), "Index out of bounds");
        return hashReservations.at(index);
    }

    /// @notice Check if an institutional user has an active booking for a specific lab
    /// @dev An active booking is one that is _CONFIRMED or _IN_USE and the current time is within [start, end]
    /// @param institutionalProvider The institution address
    /// @param puc The user's unique identifier within the institution
    /// @param labId The lab to check
    /// @return True if the user has an active booking for this lab
    function hasInstitutionalUserActiveBooking(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) external view onlyInstitution(institutionalProvider) returns (bool) {
        require(bytes(puc).length > 0, "PUC cannot be empty");

        AppStorage storage s = _s();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        bytes32 reservationKey = s.activeReservationByTokenAndUser[labId][hashKey];

        if (reservationKey == bytes32(0)) {
            return false;
        }

        Reservation storage reservation = s.reservations[reservationKey];
        uint32 time = uint32(block.timestamp);
        return (reservation.status == _CONFIRMED || reservation.status == _IN_USE) && reservation.start <= time
            && reservation.end >= time;
    }

    /// @notice Get the active reservation key for an institutional user on a specific lab
    /// @dev Returns bytes32(0) if no active booking exists
    /// @param institutionalProvider The institution address
    /// @param puc The user's unique identifier within the institution
    /// @param labId The lab to check
    /// @return reservationKey The active reservation key, or bytes32(0) if none
    function getInstitutionalUserActiveReservationKey(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) external view onlyInstitution(institutionalProvider) returns (bytes32 reservationKey) {
        require(bytes(puc).length > 0, "PUC cannot be empty");

        AppStorage storage s = _s();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        bytes32 activeKey = s.activeReservationByTokenAndUser[labId][hashKey];

        if (activeKey == bytes32(0)) {
            return bytes32(0);
        }

        Reservation storage reservation = s.reservations[activeKey];
        uint32 time = uint32(block.timestamp);
        if (
            (reservation.status == _CONFIRMED || reservation.status == _IN_USE) && reservation.start <= time
                && reservation.end >= time
        ) {
            return activeKey;
        }

        return bytes32(0);
    }

    /// @notice Get the active reservation count for an institutional user on a specific lab
    /// @param institutionalProvider The institution address
    /// @param puc The user's unique identifier within the institution
    /// @param labId The lab to check
    /// @return count The number of active reservations (including pending)
    function getInstitutionalUserActiveCount(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) external view onlyInstitution(institutionalProvider) returns (uint256 count) {
        AppStorage storage s = _s();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        return s.activeReservationCountByTokenAndUser[labId][hashKey];
    }

    /// @notice Get reservation details by key
    /// @param _reservationKey The reservation key to query
    /// @return reservation The reservation data
    function getReservation(
        bytes32 _reservationKey
    ) external view returns (Reservation memory reservation) {
        return _s().reservations[_reservationKey];
    }

    function getReservationPucHash(
        bytes32 _reservationKey
    ) external view returns (bytes32) {
        return _s().reservationPucHash[_reservationKey];
    }

    /// @notice Get the total reservations count for a lab
    /// @param labId The lab to query
    /// @return count The total number of reservations ever made for this lab
    function getLabReservationCount(
        uint256 labId
    ) external view returns (uint256 count) {
        return _s().reservationKeysByToken[labId].length();
    }

    /// @notice Get the active reservation count for a lab
    /// @param labId The lab to query
    /// @return count The number of active (non-collected, non-cancelled) reservations
    function getLabActiveReservationCount(
        uint256 labId
    ) external view returns (uint256 count) {
        return _s().labActiveReservationCount[labId];
    }
}
