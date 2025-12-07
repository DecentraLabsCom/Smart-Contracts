// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseMinimalReservationFacet} from "../base/BaseMinimalReservationFacet.sol";
import {LibAppStorage, AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";

interface IInstitutionalTreasuryFacetLight {
    function checkInstitutionalTreasuryAvailability(address provider, string calldata puc, uint256 amount) external view;
}

contract InstitutionalRequestCreationFacet is BaseMinimalReservationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct InstInput {
        address p;
        address o;
        uint256 l;
        uint32 s;
        uint32 e;
        string u;
        bytes32 k;
        address t;
    }

    function createInstReservation(InstInput calldata i) external {
        AppStorage storage s = _s();
        address hc = s.institutionalBackends[i.o];
        uint96 pr = (hc != address(0) && i.p == i.o) ? 0 : s.labs[i.l].price;

        if (pr > 0) IInstitutionalTreasuryFacetLight(address(this)).checkInstitutionalTreasuryAvailability(i.p, i.u, pr);

        uint256 d = s.institutionalSpendingPeriod[i.p];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 rs = uint64(rsAligned);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 period = uint64(d);

        s.reservationKeysByToken[i.l].add(i.k);
        s.reservations[i.k] = Reservation({
            labId: i.l,
            renter: i.p,
            labProvider: i.o,
            price: pr,
            start: i.s,
            end: i.e,
            status: _PENDING,
            puc: i.u,
            requestPeriodStart: rs,
            requestPeriodDuration: period,
            payerInstitution: i.p,
            collectorInstitution: hc != address(0) ? i.o : address(0),
            providerShare: 0,
            projectTreasuryShare: 0,
            subsidiesShare: 0,
            governanceShare: 0
        });

        s.totalReservationsCount++;
        s.renters[i.p].add(i.k);
        s.renters[i.t].add(i.k);
        s.activeReservationCountByTokenAndUser[i.l][i.t]++;
        s.reservationKeysByTokenAndUser[i.l][i.t].add(i.k);

        emit ReservationRequested(i.p, i.l, i.s, i.e, i.k);
    }

    function recordRecentInstReservation(uint256 l, address t, bytes32 k, uint32 st) external {
        _recordRecent(_s(), l, t, k, st);
    }
}
