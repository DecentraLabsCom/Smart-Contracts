// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseLightReservationFacet} from "../base/BaseLightReservationFacet.sol";
import {LibAppStorage, AppStorage, Reservation, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {RivalIntervalTreeLibrary, Tree} from "../../../libraries/RivalIntervalTreeLibrary.sol";

interface IStakingFacetConfirm {
    function updateLastReservation(address provider) external;
}

interface IInstitutionalTreasuryFacetConfirm {
    function spendFromInstitutionalTreasury(address institution, string calldata puc, uint256 amount) external;
}

contract InstitutionalConfirmationFacet is BaseLightReservationFacet {
    using RivalIntervalTreeLibrary for Tree;

    error InstitutionNotRegistered();
    error UnauthorizedInstitutionCall();

    function confirmInstitutionalReservationRequest(address i, bytes32 k) external reservationPending(k) {
        AppStorage storage s = _s();
        if (!EnumerableSet.contains(s.roleMembers[INSTITUTION_ROLE], i)) revert InstitutionNotRegistered();

        Reservation storage r = s.reservations[k];
        address labOwner = IERC721(address(this)).ownerOf(r.labId);

        address instBackend = s.institutionalBackends[i];
        address providerBackend = s.institutionalBackends[labOwner];

        bool institutionCaller = msg.sender == i || (instBackend != address(0) && msg.sender == instBackend);
        bool providerCaller = msg.sender == labOwner || (providerBackend != address(0) && msg.sender == providerBackend);

        if (!institutionCaller && !providerCaller) revert UnauthorizedInstitutionCall();

        _confirmInstitutionalReservationRequest(i, k);
    }

    function _confirmInstitutionalReservationRequest(address ip, bytes32 key) internal override {
        AppStorage storage s = _s();
        Reservation storage r = s.reservations[key];
        if (r.payerInstitution != ip || bytes(r.puc).length == 0) revert();

        address tr = _trackingKeyFromInstitution(ip, r.puc);
        address lp = IERC721(address(this)).ownerOf(r.labId);
        r.labProvider = lp;

        if (!_providerCanFulfill(s, lp, r.labId)) { _cancelReservation(key); emit ReservationRequestDenied(key, r.labId); return; }

        r.collectorInstitution = s.institutionalBackends[lp] != address(0) ? lp : address(0);

        uint256 d = r.requestPeriodDuration;
        if (d == 0) d = s.institutionalSpendingPeriod[ip];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        if (block.timestamp >= r.requestPeriodStart + d) { _cancelReservation(key); emit ReservationRequestDenied(key, r.labId); return; }

        if (r.price == 0) { _fin(s, r, key, lp, tr); return; }

        try IInstitutionalTreasuryFacetConfirm(address(this)).spendFromInstitutionalTreasury(r.payerInstitution, r.puc, r.price) {
            _fin(s, r, key, lp, tr);
        } catch { _cancelReservation(key); emit ReservationRequestDenied(key, r.labId); }
    }

    function _fin(AppStorage storage s, Reservation storage r, bytes32 k, address lp, address tr) internal {
        _setReservationSplit(r);
        s.calendars[r.labId].insert(r.start, r.end);
        r.status = _CONFIRMED;
        _incrementActiveReservationCounters(r);
        _enqueuePayoutCandidate(s, r.labId, k, r.end);
        _enqueueInstitutionalActiveReservation(s, r.labId, r, k);
        IStakingFacetConfirm(address(this)).updateLastReservation(lp);
        bytes32 x = s.activeReservationByTokenAndUser[r.labId][tr];
        if (x == bytes32(0) || r.start < s.reservations[x].start) s.activeReservationByTokenAndUser[r.labId][tr] = k;
        emit ReservationConfirmed(k, r.labId);
    }
}
