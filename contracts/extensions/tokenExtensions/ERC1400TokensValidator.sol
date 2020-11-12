/*
 * This code has not been reviewed.
 * Do not use or deploy this code before reviewing it personally first.
 */
pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";

import "./roles/Pausable.sol";
import "./roles/AllowlistedRole.sol";
import "./roles/BlocklistedRole.sol";

import "erc1820/contracts/ERC1820Client.sol";
import "../../interface/ERC1820Implementer.sol";

import "../../IERC1400.sol";

import "./IERC1400TokensValidator.sol";

/**
 * @notice Interface to the Minterrole contract
 */
interface IMinterRole {
  function isMinter(address account) external view returns (bool);
}


contract ERC1400TokensValidator is IERC1400TokensValidator, Pausable, AllowlistedRole, BlocklistedRole, ERC1820Client, ERC1820Implementer {
  using SafeMath for uint256;

  string constant internal ERC1400_TOKENS_VALIDATOR = "ERC1400TokensValidator";

  bytes4 constant internal ERC20_TRANSFER_FUNCTION_ID = bytes4(keccak256("transfer(address,uint256)"));
  bytes4 constant internal ERC20_TRANSFERFROM_FUNCTION_ID = bytes4(keccak256("transferFrom(address,address,uint256)"));

  // Mapping from token to allowlist activation status.
  mapping(address => bool) internal _allowlistActivated;

  // Mapping from token to blocklist activation status.
  mapping(address => bool) internal _blocklistActivated;

  // Mapping from token to partition granularity activation status.
  mapping(address => bool) internal _granularityByPartitionActivated;

  // Mapping from token to holds activation status.
  mapping(address => bool) internal _holdsActivated;

  // Mapping from token to self-holds activation status.
  mapping(address => bool) internal _selfHoldsActivated;

  // Mapping from token to token controllers.
  mapping(address => address[]) internal _tokenControllers;

  // Mapping from (token, operator) to token controller status.
  mapping(address => mapping(address => bool)) internal _isTokenController;

  enum HoldStatusCode {
    Nonexistent,
    Ordered,
    Executed,
    ExecutedAndKeptOpen,
    ReleasedByNotary,
    ReleasedByPayee,
    ReleasedOnExpiration
  }

  struct Hold {
    bytes32 partition;
    address sender;
    address recipient;
    address notary;
    uint256 value;
    uint256 expiration;
    bytes32 secretHash;
    bytes32 secret;
    HoldStatusCode status;
  }

  // Mapping from (token, partition) to partition granularity.
  mapping(address => mapping(bytes32 => uint256)) internal _granularityByPartition;
  
  // Mapping from (token, holdId) to hold.
  mapping(address => mapping(bytes32 => Hold)) internal _holds;

  // Mapping from (token, tokenHolder) to balance on hold.
  mapping(address => mapping(address => uint256)) internal _heldBalance;

  // Mapping from (token, tokenHolder, partition) to balance on hold of corresponding partition.
  mapping(address => mapping(address => mapping(bytes32 => uint256))) internal _heldBalanceByPartition;

  // Mapping from (token, partition) to global balance on hold of corresponding partition.
  mapping(address => mapping(bytes32 => uint256)) internal _totalHeldBalanceByPartition;

  // Total balance on hold.
  mapping(address => uint256) internal _totalHeldBalance;

  // Mapping from hold parameter's hash to hold's nonce.
  mapping(bytes32 => uint256) internal _hashNonce;

  // Mapping from (hash, nonce) to hold ID.
  mapping(bytes32 => mapping(uint256 => bytes32)) internal _holdIds;

  // Mapping from (token, partition) to partition expiry activation status.
  mapping(address => mapping(bytes32 => bool)) internal _tokenPartitionExpiryActivated;

  // Mapping from (token, patition) to partition expiry timestamp
  mapping(address => mapping(bytes32 => uint256)) internal _tokenPartitionExpiryTimestamp;

  event HoldCreated(
    address indexed token,
    bytes32 indexed holdId,
    bytes32 partition,
    address sender,
    address recipient,
    address indexed notary,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash
  );
  event HoldReleased(address indexed token, bytes32 holdId, address indexed notary, HoldStatusCode status);
  event HoldRenewed(address indexed token, bytes32 holdId, address indexed notary, uint256 oldExpiration, uint256 newExpiration);
  event HoldExecuted(address indexed token, bytes32 holdId, address indexed notary, uint256 heldValue, uint256 transferredValue, bytes32 secret);
  event HoldExecutedAndKeptOpen(address indexed token, bytes32 holdId, address indexed notary, uint256 heldValue, uint256 transferredValue, bytes32 secret);
  
  /**
   * @dev Modifier to verify if sender is a token controller.
   */
  modifier onlyTokenController(address token) {
    require(
      msg.sender == token ||
      msg.sender == Ownable(token).owner() ||
      _isTokenController[token][msg.sender],
      "Sender is not a token controller."
    );
    _;
  }

  /**
   * @dev Modifier to verify if sender is a pauser.
   */
  modifier onlyPauser(address token) {
    require(
      msg.sender == Ownable(token).owner() ||
      _isTokenController[token][msg.sender] ||
      isPauser(token, msg.sender),
      "Sender is not a pauser"
    );
    _;
  }

  /**
   * @dev Modifier to verify if sender is an allowlist admin.
   */
  modifier onlyAllowlistAdmin(address token) {
    require(
      msg.sender == Ownable(token).owner() ||
      _isTokenController[token][msg.sender] ||
      isAllowlistAdmin(token, msg.sender),
      "Sender is not an allowlist admin"
    );
    _;
  }

  /**
   * @dev Modifier to verify if sender is a blocklist admin.
   */
  modifier onlyBlocklistAdmin(address token) {
    require(
      msg.sender == Ownable(token).owner() ||
      _isTokenController[token][msg.sender] ||
      isBlocklistAdmin(token, msg.sender),
      "Sender is not a blocklist admin"
    );
    _;
  }

  constructor() public {
    ERC1820Implementer._setInterface(ERC1400_TOKENS_VALIDATOR);
  }

  /**
   * @dev Get the list of token controllers for a given token.
   * @return Setup of a given token.
   */
  function retrieveTokenSetup(address token) external view returns (bool, bool, bool, bool, bool, address[] memory) {
    return (
      _allowlistActivated[token],
      _blocklistActivated[token],
      _granularityByPartitionActivated[token],
      _holdsActivated[token],
      _selfHoldsActivated[token],
      _tokenControllers[token]
    );
  }

  /**
   * @dev Register token setup.
   */
  function registerTokenSetup(
    address token,
    bool allowlistActivated,
    bool blocklistActivated,
    bool granularityByPartitionActivated,
    bool holdsActivated,
    bool selfHoldsActivated,
    address[] calldata operators
  ) external onlyTokenController(token) {
    _allowlistActivated[token] = allowlistActivated;
    _blocklistActivated[token] = blocklistActivated;
    _granularityByPartitionActivated[token] = granularityByPartitionActivated;
    _holdsActivated[token] = holdsActivated;
    _selfHoldsActivated[token] = selfHoldsActivated;
    _setTokenControllers(token, operators);
  }

  /**
   * @dev Set list of token controllers for a given token.
   * @param token Token address.
   * @param operators Operators addresses.
   */
  function _setTokenControllers(address token, address[] memory operators) internal {
    for (uint i = 0; i<_tokenControllers[token].length; i++){
      _isTokenController[token][_tokenControllers[token][i]] = false;
    }
    for (uint j = 0; j<operators.length; j++){
      _isTokenController[token][operators[j]] = true;
    }
    _tokenControllers[token] = operators;
  }

  /**
   * @dev Verify if a token transfer can be executed or not, on the validator's perspective.
   * @param token Address of the token.
   * @param functionSig ID of the function that is called.
   * @param partition Name of the partition (left empty for ERC20 transfer).
   * @param operator Address which triggered the balance decrease (through transfer or redemption).
   * @param from Token holder.
   * @param to Token recipient for a transfer and 0x for a redemption.
   * @param value Number of tokens the token holder balance is decreased by.
   * @param data Extra information.
   * @param operatorData Extra information, attached by the operator (if any).
   * @return 'true' if the token transfer can be validated, 'false' if not.
   */
  function canValidate(
    address token,
    bytes4 functionSig,
    bytes32 partition,
    address operator,
    address from,
    address to,
    uint value,
    bytes calldata data,
    bytes calldata operatorData
  ) // Comments to avoid compilation warnings for unused variables.
    external
    view 
    returns(bool)
  {
    (bool canValidateToken,) = _canValidate(token, functionSig, partition, operator, from, to, value, data, operatorData);
    return canValidateToken;
  }

  /**
   * @dev Function called by the token contract before executing a transfer.
   * @param functionSig ID of the function that is called.
   * @param partition Name of the partition (left empty for ERC20 transfer).
   * @param operator Address which triggered the balance decrease (through transfer or redemption).
   * @param from Token holder.
   * @param to Token recipient for a transfer and 0x for a redemption.
   * @param value Number of tokens the token holder balance is decreased by.
   * @param data Extra information.
   * @param operatorData Extra information, attached by the operator (if any).
   * @return 'true' if the token transfer can be validated, 'false' if not.
   */
  function tokensToValidate(
    bytes4 functionSig,
    bytes32 partition,
    address operator,
    address from,
    address to,
    uint value,
    bytes calldata data,
    bytes calldata operatorData
  ) // Comments to avoid compilation warnings for unused variables.
    external
  {
    (bool canValidateToken, bytes32 holdId) = _canValidate(msg.sender, functionSig, partition, operator, from, to, value, data, operatorData);
    require(canValidateToken, "55"); // 0x55	funds locked (lockup period)

    if (_holdsActivated[msg.sender] && holdId != "") {
      Hold storage executableHold = _holds[msg.sender][holdId];
      _setHoldToExecuted(
        msg.sender,
        executableHold,
        holdId,
        value,
        executableHold.value,
        ""
      );
    }
  }

  /**
   * @dev Verify if a token transfer can be executed or not, on the validator's perspective.
   * @return 'true' if the token transfer can be validated, 'false' if not.
   * @return hold ID in case a hold can be executed for the given parameters.
   */
  function _canValidate(
    address token,
    bytes4 functionSig,
    bytes32 partition,
    address operator,
    address from,
    address to,
    uint value,
    bytes memory /*data*/,
    bytes memory /*operatorData*/
  ) // Comments to avoid compilation warnings for unused variables.
    internal
    view
    whenNotPaused(token)
    returns(bool, bytes32)
  {
    if(_functionRequiresValidation(functionSig)) {
      if(_allowlistActivated[token]) {
        if(!isAllowlisted(token, from) || !isAllowlisted(token, to)) {
          return (false, "");
        }
      }
      if(_blocklistActivated[token]) {
        if(isBlocklisted(token, from) || isBlocklisted(token, to)) {
          return (false, "");
        }
      }
    }

    if(_granularityByPartitionActivated[token]) {
      if(
        _granularityByPartition[token][partition] > 0 &&
        !_isMultiple(_granularityByPartition[token][partition], value)
      ) {
        return (false, "");
      } 
    }

    if (_holdsActivated[token]) {
      if(functionSig == ERC20_TRANSFERFROM_FUNCTION_ID) {
        (,, bytes32 holdId) = _retrieveHoldHashNonceId(token, partition, operator, from, to, value);
        Hold storage hold = _holds[token][holdId];
        
        if (_holdCanBeExecutedAsNotary(hold, operator, value) && value <= IERC1400(token).balanceOfByPartition(partition, from)) {
          return (true, holdId);
        }
      }
      
      if(value > _spendableBalanceOfByPartition(token, partition, from)) {
        return (false, "");
      }
    }
    
    //Do not validate transfers when the partition has expired
    if (_getPartitionExpiryActivated(token, partition)) {
      if (_getPartitionExpiryStatus(token, partition)) {
        return (false, "");
      }
    }
    return (true, "");
  }

  /**
   * @dev Get partition expiry activation status
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry activation status of the partition.
   */
  function getPartitionExpiryActivated(address token, bytes32 partition) external view returns (bool) {
    return _getPartitionExpiryActivated(token, partition);
  }
  
  /**
   * @dev Get partition expiry status
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry status of the partition.
   */
  function getPartitionExpiryStatus(address token, bytes32 partition) external view returns (bool) {
    return _getPartitionExpiryStatus(token,partition);
  }
  
  /**
   * @dev Get partition expiry timestamp
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry timestamp of the partition.
   */
  function getPartitionExpiryTimestamp(address token, bytes32 partition) external view returns (uint256) {
    return _getPartitionExpiryTimestamp(token,partition);
  }
  
  /**
   * @dev Set partition expiry activation timestamp
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @param expiryTimestamp Expiry timestamp of the partition.
   * @return Expiry activation status of the partition.
   */
  function setPartitionExpiryTimestamp(
    address token,
    bytes32 partition,
    uint256 expiryTimestamp
  )
    external
    onlyTokenController(token)
  {
    require(_getPartitionExpiryActivated(token, partition) == false, "Partition expiry is already activated");
    require(expiryTimestamp > now, "Partition expiry timestamp must be in the future");

    _tokenPartitionExpiryActivated[token][partition] = true;
    _tokenPartitionExpiryTimestamp[token][partition] = expiryTimestamp;
  }

  /**
   * @dev Allow controllers to move expired tokens
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @param recipient Address of the recipient.
   * @return Transfer status.
   */
  function transferExpiredTokens(
    address token,
    bytes32 partition,
    address recipient
  )
    external
    onlyTokenController(token)
  {
    require(_getPartitionExpiryStatus(token, partition), "Partition must have expired");
    // todo: move tokens
  }

  /**
   * @dev Get partition expiry activation status
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry activation status of the partition.
   */
  function _getPartitionExpiryActivated(address token, bytes32 partition) internal view returns (bool) {
    return _tokenPartitionExpiryActivated[token][partition];
  }
  
  /**
   * @dev Get partition expiry status
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry status of the partition.
   */
  function _getPartitionExpiryStatus(address token, bytes32 partition) internal view returns (bool) {
    require(_getPartitionExpiryActivated(token, partition), "Partition expiry is not activated");
    return _tokenPartitionExpiryTimestamp[token][partition] < now;
  }
  
  /**
   * @dev Get partition expiry timestamp
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Expiry timestamp of the partition.
   */
  function _getPartitionExpiryTimestamp(address token, bytes32 partition) internal view returns (uint256) {
    require(_getPartitionExpiryActivated(token, partition), "Partition expiry is not activated");
    return _tokenPartitionExpiryTimestamp[token][partition];
  }
  
  /**
   * @dev Get granularity for a given partition.
   * @param token Address of the token.
   * @param partition Name of the partition.
   * @return Granularity of the partition.
   */
  function granularityByPartition(address token, bytes32 partition) external view returns (uint256) {
    return _granularityByPartition[token][partition];
  }
  
  /**
   * @dev Set partition granularity
   */
  function setGranularityByPartition(
    address token,
    bytes32 partition,
    uint256 granularity
  )
    external
    onlyTokenController(token)
  {
    _granularityByPartition[token][partition] = granularity;
  }

  /**
   * @dev Create a new token pre-hold.
   */
  function preHoldFor(
    address token,
    bytes32 holdId,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 timeToExpiration,
    bytes32 secretHash
  )
    external
    returns (bool)
  {
    return _createHold(
      token,
      holdId,
      address(0),
      recipient,
      notary,
      partition,
      value,
      _computeExpiration(timeToExpiration),
      secretHash
    );
  }

  /**
   * @dev Create a new token pre-hold with expiration date.
   */
  function preHoldForWithExpirationDate(
    address token,
    bytes32 holdId,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash
  )
    external
    returns (bool)
  {
    _checkExpiration(expiration);

    return _createHold(
      token,
      holdId,
      address(0),
      recipient,
      notary,
      partition,
      value,
      expiration,
      secretHash
    );
  }

  /**
   * @dev Create a new token hold.
   */
  function hold(
    address token,
    bytes32 holdId,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 timeToExpiration,
    bytes32 secretHash
  ) 
    external
    returns (bool)
  {
    return _createHold(
      token,
      holdId,
      msg.sender,
      recipient,
      notary,
      partition,
      value,
      _computeExpiration(timeToExpiration),
      secretHash
    );
  }

  /**
   * @dev Create a new token hold on behalf of the token holder.
   */
  function holdFrom(
    address token,
    bytes32 holdId,
    address sender,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 timeToExpiration,
    bytes32 secretHash
  )
    external
    returns (bool)
  {
    require(sender != address(0), "Payer address must not be zero address");
    return _createHold(
      token,
      holdId,
      sender,
      recipient,
      notary,
      partition,
      value,
      _computeExpiration(timeToExpiration),
      secretHash
    );
  }

  /**
   * @dev Create a new token hold with expiration date.
   */
  function holdWithExpirationDate(
    address token,
    bytes32 holdId,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash
  )
    external
    returns (bool)
  {
    _checkExpiration(expiration);

    return _createHold(
      token,
      holdId,
      msg.sender,
      recipient,
      notary,
      partition,
      value,
      expiration,
      secretHash
    );
  }

  /**
   * @dev Create a new token hold with expiration date on behalf of the token holder.
   */
  function holdFromWithExpirationDate(
    address token,
    bytes32 holdId,
    address sender,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash
  )
    external
    returns (bool)
  {
    _checkExpiration(expiration);
    require(sender != address(0), "Payer address must not be zero address");

    return _createHold(
      token,
      holdId,
      sender,
      recipient,
      notary,
      partition,
      value,
      expiration,
      secretHash
    );
  }

  /**
   * @dev Create a new token hold.
   */
  function _createHold(
    address token,
    bytes32 holdId,
    address sender,
    address recipient,
    address notary,
    bytes32 partition,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash
  ) internal returns (bool)
  {
    Hold storage newHold = _holds[token][holdId];

    require(recipient != address(0), "Payee address must not be zero address");
    require(value != 0, "Value must be greater than zero");
    require(newHold.value == 0, "This holdId already exists");
    require(notary != address(0), "Notary address must not be zero address");
    
    if (sender == address(0)) { // pre-hold (tokens do not already exist)
      require(
        _canPreHold(token, msg.sender),
        "The pre-hold can only be created by the minter"
      );
    } else { // post-hold (tokens already exist)
      require(value <= _spendableBalanceOfByPartition(token, partition, sender), "Amount of the hold can't be greater than the spendable balance of the sender");
      require(
        _canPostHold(token, partition, msg.sender, sender),
        "The hold can only be renewed by the issuer or the payer"
      );
    }
    
    newHold.partition = partition;
    newHold.sender = sender;
    newHold.recipient = recipient;
    newHold.notary = notary;
    newHold.value = value;
    newHold.expiration = expiration;
    newHold.secretHash = secretHash;
    newHold.status = HoldStatusCode.Ordered;

    if(sender != address(0)) {
      // In case tokens already exist, increase held balance
      _increaseHeldBalance(token, newHold, holdId);
    }

    emit HoldCreated(
      token,
      holdId,
      partition,
      sender,
      recipient,
      notary,
      value,
      expiration,
      secretHash
    );

    return true;
  }

  /**
   * @dev Release token hold.
   */
  function releaseHold(address token, bytes32 holdId) external returns (bool) {
    return _releaseHold(token, holdId);
  }

  /**
   * @dev Release token hold.
   */
  function _releaseHold(address token, bytes32 holdId) internal returns (bool) {
    Hold storage releasableHold = _holds[token][holdId];

    require(
        releasableHold.status == HoldStatusCode.Ordered || releasableHold.status == HoldStatusCode.ExecutedAndKeptOpen,
        "A hold can only be released in status Ordered or ExecutedAndKeptOpen"
    );
    require(
        _isExpired(releasableHold.expiration) ||
        (msg.sender == releasableHold.notary) ||
        (msg.sender == releasableHold.recipient),
        "A not expired hold can only be released by the notary or the payee"
    );

    if (_isExpired(releasableHold.expiration)) {
        releasableHold.status = HoldStatusCode.ReleasedOnExpiration;
    } else {
        if (releasableHold.notary == msg.sender) {
            releasableHold.status = HoldStatusCode.ReleasedByNotary;
        } else {
            releasableHold.status = HoldStatusCode.ReleasedByPayee;
        }
    }

    if(releasableHold.sender != address(0)) { // In case tokens already exist, decrease held balance
      _decreaseHeldBalance(token, releasableHold, releasableHold.value);
    }

    emit HoldReleased(token, holdId, releasableHold.notary, releasableHold.status);

    return true;
  }

  /**
   * @dev Renew hold.
   */
  function renewHold(address token, bytes32 holdId, uint256 timeToExpiration) external returns (bool) {
    return _renewHold(token, holdId, _computeExpiration(timeToExpiration));
  }

  /**
   * @dev Renew hold with expiration time.
   */
  function renewHoldWithExpirationDate(address token, bytes32 holdId, uint256 expiration) external returns (bool) {
    _checkExpiration(expiration);

    return _renewHold(token, holdId, expiration);
  }

  /**
   * @dev Renew hold.
   */
  function _renewHold(address token, bytes32 holdId, uint256 expiration) internal returns (bool) {
    Hold storage renewableHold = _holds[token][holdId];

    require(
      renewableHold.status == HoldStatusCode.Ordered
      || renewableHold.status == HoldStatusCode.ExecutedAndKeptOpen,
      "A hold can only be renewed in status Ordered or ExecutedAndKeptOpen"
    );
    require(!_isExpired(renewableHold.expiration), "An expired hold can not be renewed");

    if (renewableHold.sender == address(0)) { // pre-hold (tokens do not already exist)
      require(
        _canPreHold(token, msg.sender),
        "The pre-hold can only be renewed by the minter"
      );
    } else { // post-hold (tokens already exist)
      require(
        _canPostHold(token, renewableHold.partition, msg.sender, renewableHold.sender),
        "The hold can only be renewed by the issuer or the payer"
      );
    }
    
    uint256 oldExpiration = renewableHold.expiration;
    renewableHold.expiration = expiration;

    emit HoldRenewed(
      token,
      holdId,
      renewableHold.notary,
      oldExpiration,
      expiration
    );

    return true;
  }

  /**
   * @dev Execute hold.
   */
  function executeHold(address token, bytes32 holdId, uint256 value, bytes32 secret) external returns (bool) {
    return _executeHold(
      token,
      holdId,
      msg.sender,
      value,
      secret,
      false
    );
  }

  /**
   * @dev Execute hold and keep open.
   */
  function executeHoldAndKeepOpen(address token, bytes32 holdId, uint256 value, bytes32 secret) external returns (bool) {
    return _executeHold(
      token,
      holdId,
      msg.sender,
      value,
      secret,
      true
    );
  }
  
  /**
   * @dev Execute hold.
   */
  function _executeHold(
    address token,
    bytes32 holdId,
    address operator,
    uint256 value,
    bytes32 secret,
    bool keepOpenIfHoldHasBalance
  ) internal returns (bool)
  {
    Hold storage executableHold = _holds[token][holdId];

    bool canExecuteHold;
    if(secret != "" && _holdCanBeExecutedAsSecretHolder(executableHold, value, secret)) {
      executableHold.secret = secret;
      canExecuteHold = true;
    } else if(_holdCanBeExecutedAsNotary(executableHold, operator, value)) {
      canExecuteHold = true;
    }

    if(canExecuteHold) {
      if (keepOpenIfHoldHasBalance && ((executableHold.value - value) > 0)) {
        _setHoldToExecutedAndKeptOpen(
          token,
          executableHold,
          holdId,
          value,
          value,
          secret
        );
      } else {
        _setHoldToExecuted(
          token,
          executableHold,
          holdId,
          value,
          executableHold.value,
          secret
        );
      }

      if (executableHold.sender == address(0)) { // pre-hold (tokens do not already exist)
        IERC1400(token).issueByPartition(executableHold.partition, executableHold.recipient, value, "");
      } else { // post-hold (tokens already exist)
        IERC1400(token).operatorTransferByPartition(executableHold.partition, executableHold.sender, executableHold.recipient, value, "", "");
      }
      
    } else {
      revert("hold can not be executed");
    }

  }

  /**
   * @dev Set hold to executed.
   */
  function _setHoldToExecuted(
    address token,
    Hold storage executableHold,
    bytes32 holdId,
    uint256 value,
    uint256 heldBalanceDecrease,
    bytes32 secret
  ) internal
  {
    if(executableHold.sender != address(0)) { // In case tokens already exist, decrease held balance
      _decreaseHeldBalance(token, executableHold, heldBalanceDecrease);
    }

    executableHold.status = HoldStatusCode.Executed;

    emit HoldExecuted(
      token,
      holdId,
      executableHold.notary,
      executableHold.value,
      value,
      secret
    );
  }

  /**
   * @dev Set hold to executed and kept open.
   */
  function _setHoldToExecutedAndKeptOpen(
    address token,
    Hold storage executableHold,
    bytes32 holdId,
    uint256 value,
    uint256 heldBalanceDecrease,
    bytes32 secret
  ) internal
  {
    if(executableHold.sender != address(0)) { // In case tokens already exist, decrease held balance
      _decreaseHeldBalance(token, executableHold, heldBalanceDecrease);
    } 

    executableHold.status = HoldStatusCode.ExecutedAndKeptOpen;
    executableHold.value = executableHold.value.sub(value);

    emit HoldExecutedAndKeptOpen(
      token,
      holdId,
      executableHold.notary,
      executableHold.value,
      value,
      secret
    );
  }

  /**
   * @dev Increase held balance.
   */
  function _increaseHeldBalance(address token, Hold storage executableHold, bytes32 holdId) private {
    _heldBalance[token][executableHold.sender] = _heldBalance[token][executableHold.sender].add(executableHold.value);
    _totalHeldBalance[token] = _totalHeldBalance[token].add(executableHold.value);

    _heldBalanceByPartition[token][executableHold.sender][executableHold.partition] = _heldBalanceByPartition[token][executableHold.sender][executableHold.partition].add(executableHold.value);
    _totalHeldBalanceByPartition[token][executableHold.partition] = _totalHeldBalanceByPartition[token][executableHold.partition].add(executableHold.value);

    _increaseNonce(token, executableHold, holdId);
  }

  /**
   * @dev Decrease held balance.
   */
  function _decreaseHeldBalance(address token, Hold storage executableHold, uint256 value) private {
    _heldBalance[token][executableHold.sender] = _heldBalance[token][executableHold.sender].sub(value);
    _totalHeldBalance[token] = _totalHeldBalance[token].sub(value);

    _heldBalanceByPartition[token][executableHold.sender][executableHold.partition] = _heldBalanceByPartition[token][executableHold.sender][executableHold.partition].sub(value);
    _totalHeldBalanceByPartition[token][executableHold.partition] = _totalHeldBalanceByPartition[token][executableHold.partition].sub(value);

    if(executableHold.status == HoldStatusCode.Ordered) {
      _decreaseNonce(token, executableHold);
    }
  }

  /**
   * @dev Increase nonce.
   */
  function _increaseNonce(address token, Hold storage executableHold, bytes32 holdId) private {
    (bytes32 holdHash, uint256 nonce,) = _retrieveHoldHashNonceId(
      token, executableHold.partition,
      executableHold.notary,
      executableHold.sender,
      executableHold.recipient,
      executableHold.value
    );
    _hashNonce[holdHash] = nonce.add(1);
    _holdIds[holdHash][nonce.add(1)] = holdId;
  }

  /**
   * @dev Decrease nonce.
   */
  function _decreaseNonce(address token, Hold storage executableHold) private {
    (bytes32 holdHash, uint256 nonce,) = _retrieveHoldHashNonceId(
      token,
      executableHold.partition,
      executableHold.notary,
      executableHold.sender,
      executableHold.recipient,
      executableHold.value
    );
    _holdIds[holdHash][nonce] = "";
    _hashNonce[holdHash] = _hashNonce[holdHash].sub(1);
  }

  /**
   * @dev Check secret.
   */
  function _checkSecret(Hold storage executableHold, bytes32 secret) internal view returns (bool) {
    if(executableHold.secretHash == sha256(abi.encodePacked(secret))) {
      return true;
    } else {
      return false;
    }
  }

  /**
   * @dev Compute expiration time.
   */
  function _computeExpiration(uint256 timeToExpiration) internal view returns (uint256) {
    uint256 expiration = 0;

    if (timeToExpiration != 0) {
        expiration = now.add(timeToExpiration);
    }

    return expiration;
  }

  /**
   * @dev Check expiration time.
   */
  function _checkExpiration(uint256 expiration) private view {
    require(expiration > now || expiration == 0, "Expiration date must be greater than block timestamp or zero");
  }

  /**
   * @dev Check is expiration date is past.
   */
  function _isExpired(uint256 expiration) internal view returns (bool) {
    return expiration != 0 && (now >= expiration);
  }

  /**
   * @dev Retrieve hold hash, nonce, and ID for given parameters
   */
  function _retrieveHoldHashNonceId(address token, bytes32 partition, address notary, address sender, address recipient, uint value) internal view returns (bytes32, uint256, bytes32) {
    // Pack and hash hold parameters
    bytes32 holdHash = keccak256(abi.encodePacked(
      token,
      partition,
      sender,
      recipient,
      notary,
      value
    ));
    uint256 nonce = _hashNonce[holdHash];
    bytes32 holdId = _holdIds[holdHash][nonce];

    return (holdHash, nonce, holdId);
  }  

  /**
   * @dev Check if hold can be executed
   */
  function _holdCanBeExecuted(Hold storage executableHold, uint value) internal view returns (bool) {
    if(!(executableHold.status == HoldStatusCode.Ordered || executableHold.status == HoldStatusCode.ExecutedAndKeptOpen)) {
      return false; // A hold can only be executed in status Ordered or ExecutedAndKeptOpen
    } else if(value == 0) {
      return false; // Value must be greater than zero
    } else if(_isExpired(executableHold.expiration)) {
      return false; // The hold has already expired
    } else if(value > executableHold.value) {
      return false; // The value should be equal or less than the held amount
    } else {
      return true;
    }
  }

  /**
   * @dev Check if hold can be executed as secret holder
   */
  function _holdCanBeExecutedAsSecretHolder(Hold storage executableHold, uint value, bytes32 secret) internal view returns (bool) {
    if(
      _checkSecret(executableHold, secret)
      && _holdCanBeExecuted(executableHold, value)) {
      return true;
    } else {
      return false;
    }
  }

  /**
   * @dev Check if hold can be executed as notary
   */
  function _holdCanBeExecutedAsNotary(Hold storage executableHold, address operator, uint value) internal view returns (bool) {
    if(
      executableHold.notary == operator
      && _holdCanBeExecuted(executableHold, value)) {
      return true;
    } else {
      return false;
    }
  }  

  /**
   * @dev Retrieve hold data.
   */
  function retrieveHoldData(address token, bytes32 holdId) external view returns (
    bytes32 partition,
    address sender,
    address recipient,
    address notary,
    uint256 value,
    uint256 expiration,
    bytes32 secretHash,
    bytes32 secret,
    HoldStatusCode status)
  {
    Hold storage retrievedHold = _holds[token][holdId];
    return (
      retrievedHold.partition,
      retrievedHold.sender,
      retrievedHold.recipient,
      retrievedHold.notary,
      retrievedHold.value,
      retrievedHold.expiration,
      retrievedHold.secretHash,
      retrievedHold.secret,
      retrievedHold.status
    );
  }

  /**
   * @dev Total supply on hold.
   */
  function totalSupplyOnHold(address token) external view returns (uint256) {
    return _totalHeldBalance[token];
  }

  /**
   * @dev Total supply on hold for a specific partition.
   */
  function totalSupplyOnHoldByPartition(address token, bytes32 partition) external view returns (uint256) {
    return _totalHeldBalanceByPartition[token][partition];
  }

  /**
   * @dev Get balance on hold of a tokenholder.
   */
  function balanceOnHold(address token, address account) external view returns (uint256) {
    return _heldBalance[token][account];
  }

  /**
   * @dev Get balance on hold of a tokenholder for a specific partition.
   */
  function balanceOnHoldByPartition(address token, bytes32 partition, address account) external view returns (uint256) {
    return _heldBalanceByPartition[token][account][partition];
  }

  /**
   * @dev Get spendable balance of a tokenholder.
   */
  function spendableBalanceOf(address token, address account) external view returns (uint256) {
    return _spendableBalanceOf(token, account);
  }

  /**
   * @dev Get spendable balance of a tokenholder for a specific partition.
   */
  function spendableBalanceOfByPartition(address token, bytes32 partition, address account) external view returns (uint256) {
    return _spendableBalanceOfByPartition(token, partition, account);
  }

  /**
   * @dev Get spendable balance of a tokenholder.
   */
  function _spendableBalanceOf(address token, address account) internal view returns (uint256) {
    return IERC20(token).balanceOf(account) - _heldBalance[token][account];
  }

  /**
   * @dev Get spendable balance of a tokenholder for a specific partition.
   */
  function _spendableBalanceOfByPartition(address token, bytes32 partition, address account) internal view returns (uint256) {
    return IERC1400(token).balanceOfByPartition(partition, account) - _heldBalanceByPartition[token][account][partition];
  }

  /************************** TOKEN CONTROLLERS *******************************/

  /**
   * @dev Check if operator can create pre-holds.
   * @return 'true' if the operator can create pre-holds, 'false' if not.
   */
  function _canPreHold(address token, address operator) internal view returns(bool) { 
    return IMinterRole(token).isMinter(operator);
  }

  /**
   * @dev Check if operator can create/update holds.
   * @return 'true' if the operator can create/update holds, 'false' if not.
   */
  function _canPostHold(address token, bytes32 partition, address operator, address sender) internal view returns(bool) {    
    if (_selfHoldsActivated[token]) {
      return IERC1400(token).isOperatorForPartition(partition, operator, sender);
    } else {
      return _isTokenController[token][operator];
    }
  }


  /**
   * @dev Check if validator is activated for the function called in the smart contract.
   * @param functionSig ID of the function that is called.
   * @return 'true' if the function requires validation, 'false' if not.
   */
  function _functionRequiresValidation(bytes4 functionSig) internal pure returns(bool) {
    if(_areEqual(functionSig, ERC20_TRANSFER_FUNCTION_ID) || _areEqual(functionSig, ERC20_TRANSFERFROM_FUNCTION_ID)) {
      return true;
    } else {
      return false;
    }
  }

  /**
   * @dev Check if 2 variables of type bytes4 are identical.
   * @return 'true' if 2 variables are identical, 'false' if not.
   */
  function _areEqual(bytes4 a, bytes4 b) internal pure returns(bool) {
    for (uint256 i = 0; i < a.length; i++) {
      if(a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * @dev Check if 'value' is multiple of 'granularity'.
   * @param granularity The granularity that want's to be checked.
   * @param value The quantity that want's to be checked.
   * @return 'true' if 'value' is a multiple of 'granularity'.
   */
  function _isMultiple(uint256 granularity, uint256 value) internal pure returns(bool) {
    return(value.div(granularity).mul(granularity) == value);
  }

}