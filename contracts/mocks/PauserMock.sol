pragma solidity ^0.5.0;

// MOCK CONTRACT TO REACH FULL COVERAGE BY CALLING "onlyNotPausered" MODIFIER

import "../extensions/tokenExtensions/roles/PauserRole.sol";


contract PauserMock is PauserRole {

  bool _mockActivated;

  constructor(address token) public {
    _addPauser(token, msg.sender);
  }

  function mockFunction(address token, bool mockActivated) external onlyPauser(token) {
    _mockActivated = mockActivated;
  }

}