// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BaseWalletReservationFacet, IStakingFacetW} from "../base/BaseWalletReservationFacet.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";

/// @title WalletReservationFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage wallet reservations
/// @notice Provides functions to handle wallet reservation requests,
/// confirmations, denials, cancellations, and expired reservation releases.
/// @dev Payout utilities (`requestFunds`, `getPendingLabPayout`) live here even for
/// institutional labs, because the ERC20 transfer logic and treasury accruals are
/// shared. Institutional providers invoke the same functions via the diamond router.

contract WalletReservationFacet is BaseWalletReservationFacet, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // NOTE: reservationRequest(), confirmReservationRequest(), denyReservationRequest()
    // moved to WalletReservationCoreFacet for contract size optimization

    // NOTE: cancelReservationRequest(), cancelBooking()
    // moved to WalletCancellationFacet for contract size optimization

    // NOTE: requestFunds(), requestFundsWithIntent(), getLabTokenAddress(), getSafeBalance()
    // getPendingLabPayout(), initializeRevenueRecipients(), withdrawProjectTreasury(),
    // withdrawSubsidies(), withdrawGovernance(), adminRecoverOrphanedPayouts()
    // moved to WalletPayoutFacet for contract size optimization

    function releaseExpiredReservations(uint256 _labId, address _user, uint256 maxBatch)
        external
        returns (uint256 processed)
    {
        if (msg.sender != _user) revert("Only user can release their quota");
        return _releaseExpiredReservations(_labId, _user, maxBatch);
    }

    // NOTE: _requireLabProviderOrBackend moved to WalletReservationCoreFacet

    // ---------------------------------------------------------------------
    // Internal overrides
    // ---------------------------------------------------------------------

    function _requestFunds(uint256 _labId, uint256 maxBatch) internal override {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed;
        uint256 currentTime = block.timestamp;

        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, currentTime);
            if (key == bytes32(0)) {
                break;
            }
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationForPayout(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        uint256 providerPayout = s.pendingProviderPayout[_labId];
        if (providerPayout == 0 && processed == 0) revert("No completed reservations");

        if (providerPayout > 0) {
            IERC20(s.labTokenAddress).safeTransfer(labOwner, providerPayout);
            s.pendingProviderPayout[_labId] = 0;
        }

        if (processed > 0) {
            IStakingFacetW(address(this)).updateLastReservation(labOwner);
        }

        emit FundsCollected(labOwner, _labId, providerPayout, processed);
    }

    function _getLabTokenAddress() internal view override returns (address){
        return _s().labTokenAddress;
    }

    function _getSafeBalance() internal view override returns (uint256){ 
        return IERC20(_s().labTokenAddress).balanceOf(address(this));
    }

    function _releaseExpiredReservations(uint256 _labId, address _user, uint256 maxBatch) internal override returns (uint256){
        // Only the user can release their own quota to prevent manipulation
        if (msg.sender != _user) {
            revert("Only user can release their quota");
        }
        
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");
        
        // Delegate to internal function
        return _releaseExpiredReservationsInternal(_labId, _user, maxBatch);
    }
}
