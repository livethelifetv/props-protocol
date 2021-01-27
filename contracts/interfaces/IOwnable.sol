// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.7.0;

interface IOwnable {
    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;
}