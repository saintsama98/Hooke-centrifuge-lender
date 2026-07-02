//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

///@notice this contract touches other especially the tranche.sol in since this contract was meant to be build keeping
//in mind that this shall be user facing in the first place

import "./tranche.sol";

contract Operator is Auth {}
