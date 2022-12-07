// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ILBFactory {
    function getLBPairInformation(
        address _tokenA,
        address _tokenB,
        uint256 _binStep
    )
        external
        view
        returns (
            uint24 binStep,
            address lbPair,
            bool createdByOwner,
            bool ignoredForRouting
        );
}
