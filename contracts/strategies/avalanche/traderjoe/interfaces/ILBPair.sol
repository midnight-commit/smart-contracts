// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ILBPair {
    function tokenX() external view returns (address);

    function tokenY() external view returns (address);

    function getReservesAndId()
        external
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 activeId
        );

    function getBin(uint24 id) external view returns (uint256 reserveX, uint256 reserveY);

    function pendingFees(address account, uint256[] memory ids)
        external
        view
        returns (uint256 amountX, uint256 amountY);

    function swap(bool sentTokenY, address to) external returns (uint256 amountXOut, uint256 amountYOut);

    function balanceOf(address account, uint256 binId) external view returns (uint256 amount);

    function balanceOfBatch(address[] calldata _accounts, uint256[] calldata _ids)
        external
        view
        returns (uint256[] memory batchBalances);

    function totalSupply(uint256 binId) external view returns (uint256);

    function setApprovalForAll(address sender, bool approved) external;

    function collectFees(address account, uint256[] memory ids) external returns (uint256 amountX, uint256 amountY);
}
