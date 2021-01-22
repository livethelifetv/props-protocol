// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IAppToken {
    function pause() external;

    function unpause() external;

    function whitelistAddress(address _account) external;

    function blacklistAddress(address _account) external;
}
