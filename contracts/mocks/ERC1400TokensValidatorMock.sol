pragma solidity ^0.5.0;

import "../extensions/tokenExtensions/ERC1400TokensValidator.sol";

/**
 @notice Interface to the Minterrole contract
*/
interface IMinterRoleMock {
  function renounceMinter() external;
}

contract ERC1400TokensValidatorMock is ERC1400TokensValidator {

  function renounceMinter(address token) external onlyTokenController(token) {
    IMinterRoleMock(token).renounceMinter();
  }

}