// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseLightReservationFacet} from "../base/BaseLightReservationFacet.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";
import {ReservableToken} from "../../../abstracts/ReservableToken.sol";

contract InstitutionalRequestValidationFacet is BaseLightReservationFacet {

    error InstitutionalBackendMissing();
    error OnlyInstitutionalBackend();
    error InvalidInstitutionalUserId();

    function validateInstRequest(
        address p,
        string calldata u,
        uint256 l,
        uint32 st,
        uint32 en
    ) external returns (address o, bytes32 k, address t) {
        AppStorage storage s = _s();
        if (s.institutionalBackends[p] == address(0)) revert InstitutionalBackendMissing();
        if (msg.sender != s.institutionalBackends[p]) revert OnlyInstitutionalBackend();
        if (bytes(u).length == 0 || bytes(u).length > 256) revert InvalidInstitutionalUserId();
        if (!s.tokenStatus[l]) revert();

        o = IERC721(address(this)).ownerOf(l);
        if (s.providerStakes[o].stakedAmount < ReservableToken(address(this)).calculateRequiredStake(o, s.providerStakes[o].listedLabsCount)) {
            revert();
        }
        if (st >= en || st <= block.timestamp + _RESERVATION_MARGIN) revert();

        k = _getReservationKey(l, st);
        t = _trackingKeyFromInstitution(p, u);

        uint256 c = s.activeReservationCountByTokenAndUser[l][t];
        if (c >= _MAX_RESERVATIONS_PER_LAB_USER - 2) {
            _releaseExpiredReservationsInternal(l, t, _MAX_RESERVATIONS_PER_LAB_USER);
            c = s.activeReservationCountByTokenAndUser[l][t];
        }
        if (c >= _MAX_RESERVATIONS_PER_LAB_USER) revert MaxReservationsReached();

        Reservation storage ex = s.reservations[k];
        if (ex.renter != address(0) && ex.status != _CANCELLED && ex.status != _COLLECTED) revert();
    }
}
