// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Ownable.sol";

abstract contract Permissioned is Ownable {
    uint256 public numberOfAllowedDepositors;
    mapping(address => bool) public allowedDepositors;

    event AllowDepositor(address indexed account);
    event RemoveDepositor(address indexed account);

    error OnlyAllowedDepositors();
    error DepositorAlreadyAllowed();
    error NoAllowedDepositors();
    error DepositorNotAllowed();

    modifier onlyAllowedDeposits() {
        if (numberOfAllowedDepositors > 0) {
            if (!allowedDepositors[msg.sender]) revert OnlyAllowedDepositors();
        }
        _;
    }

    /**
     * @notice Add an allowed depositor
     * @param depositor address
     */
    function allowDepositor(address depositor) external onlyOwner {
        if (allowedDepositors[depositor]) revert DepositorAlreadyAllowed();
        allowedDepositors[depositor] = true;
        numberOfAllowedDepositors = numberOfAllowedDepositors + 1;
        emit AllowDepositor(depositor);
    }

    /**
     * @notice Remove an allowed depositor
     * @param depositor address
     */
    function removeDepositor(address depositor) external onlyOwner {
        if (numberOfAllowedDepositors == 0) revert NoAllowedDepositors();
        if (!allowedDepositors[depositor]) revert DepositorNotAllowed();
        allowedDepositors[depositor] = false;
        numberOfAllowedDepositors = numberOfAllowedDepositors - 1;
        emit RemoveDepositor(depositor);
    }
}
