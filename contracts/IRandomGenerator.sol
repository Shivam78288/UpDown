// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
interface IRandomGenerator{
    
    function latestRoundData(uint256 modulus) external returns (uint256, uint256, uint256);
    
    function getSeed() external view returns(uint256);
    function setSeed(uint256 _seed) external; 
    function getCounter() external view returns(uint256);
    function addViewRole(address account) external;
    function removeFromViewRole(address account) external;
}
