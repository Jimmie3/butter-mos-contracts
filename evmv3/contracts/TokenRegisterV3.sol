// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./interface/IVaultTokenV3.sol";
import "./interface/ITokenRegisterV3.sol";
import "@mapprotocol/protocol/contracts/utils/Utils.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

contract TokenRegisterV3 is ITokenRegisterV3, UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    uint256 constant MAX_RATE_UNI = 1000000;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct FeeRate {
        uint256 lowest;
        uint256 highest;
        uint256 rate; // unit is parts per million
    }

    struct Token {
        uint8 decimals;
        address vaultToken;
        mapping(uint256 => FeeRate) fees;
        mapping(uint256 => FeeRate) outFees;
        // chain_id => decimals
        mapping(uint256 => uint8) tokenDecimals;
        // chain_id => token
        mapping(uint256 => bytes) mappingTokens;
    }

    uint256 public immutable selfChainId = block.chainid;

    //Source chain to Relay chain address
    // [chain_id => [source_token => map_token]]
    mapping(uint256 => mapping(bytes => address)) public tokenMappingList;

    mapping(address => Token) public tokenList;

    modifier checkAddress(address _address) {
        require(_address != address(0), "address is zero");
        _;
    }

    event RegisterToken(address _token, address _vaultToken);
    event SetTokenFee(address _token, uint256 _toChain, uint256 _lowest, uint256 _highest, uint256 _rate);
    event SetTransferOutTokenFee(address _token, uint256 _toChain, uint256 _lowest, uint256 _highest, uint256 _rate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _defaultAdmin) public initializer checkAddress(_defaultAdmin) {
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
    }

    function registerToken(
        address _token,
        address _vaultToken
    ) external onlyRole(MANAGER_ROLE) checkAddress(_token) checkAddress(_vaultToken) {
        Token storage token = tokenList[_token];
        address tokenAddress = IVaultTokenV3(_vaultToken).getTokenAddress();
        require(_token == tokenAddress, "invalid vault token");

        token.vaultToken = _vaultToken;
        token.decimals = IERC20MetadataUpgradeable(_token).decimals();
        // token.mintable = _mintable;
        emit RegisterToken(_token, _vaultToken);
    }

    function mapToken(
        address _token,
        uint256 _fromChain,
        bytes memory _fromToken,
        uint8 _decimals
    ) external onlyRole(MANAGER_ROLE) checkAddress(_token) {
        require(!Utils.checkBytes(_fromToken, bytes("")), "invalid from token");
        Token storage token = tokenList[_token];
        //require(token.vaultToken != address(0), "invalid map token");
        token.tokenDecimals[_fromChain] = _decimals;
        token.mappingTokens[_fromChain] = _fromToken;
        tokenMappingList[_fromChain][_fromToken] = _token;
    }

    function setTransferOutFee(
        address _token,
        uint256 _fromChain,
        uint256 _lowest,
        uint256 _highest,
        uint256 _rate
    ) external onlyRole(MANAGER_ROLE) checkAddress(_token) {
        Token storage token = tokenList[_token];
        require(token.vaultToken != address(0), "invalid map token");
        require(_highest >= _lowest, "invalid highest and lowest");
        require(_rate <= MAX_RATE_UNI, "invalid proportion value");

        token.outFees[_fromChain] = FeeRate(_lowest, _highest, _rate);

        emit SetTransferOutTokenFee(_token, _fromChain, _lowest, _highest, _rate);
    }

    function setTokenFee(
        address _token,
        uint256 _toChain,
        uint256 _lowest,
        uint256 _highest,
        uint256 _rate
    ) external onlyRole(MANAGER_ROLE) checkAddress(_token) {
        Token storage token = tokenList[_token];
        require(token.vaultToken != address(0), "invalid map token");
        require(_highest >= _lowest, "invalid highest and lowest");
        require(_rate <= MAX_RATE_UNI, "invalid proportion value");

        token.fees[_toChain] = FeeRate(_lowest, _highest, _rate);

        emit SetTokenFee(_token, _toChain, _lowest, _highest, _rate);
    }

    // --------------------------------------------------------

    function getToChainToken(
        address _token,
        uint256 _toChain
    ) external view override returns (bytes memory _toChainToken) {
        if (_toChain == selfChainId) {
            _toChainToken = Utils.toBytes(_token);
        } else {
            _toChainToken = tokenList[_token].mappingTokens[_toChain];
        }
    }

    function getToChainAmount(
        address _token,
        uint256 _amount,
        uint256 _toChain
    ) external view override returns (uint256) {
        if (_toChain == selfChainId) {
            return _amount;
        }
        uint256 decimalsFrom = tokenList[_token].decimals;

        require(decimalsFrom > 0, "from token decimals not register");

        uint256 decimalsTo = tokenList[_token].tokenDecimals[_toChain];

        require(decimalsTo > 0, "from token decimals not register");

        if (decimalsFrom == decimalsTo) {
            return _amount;
        }
        return (_amount * (10 ** decimalsTo)) / (10 ** decimalsFrom);
    }

    function getRelayChainToken(
        uint256 _fromChain,
        bytes memory _fromToken
    ) external view override returns (address token) {
        if (_fromChain == selfChainId) {
            token = Utils.fromBytes(_fromToken);
        } else {
            token = tokenMappingList[_fromChain][_fromToken];
        }
    }

    function getRelayChainAmount(
        address _token,
        uint256 _fromChain,
        uint256 _amount
    ) external view override returns (uint256) {
        if (_fromChain == selfChainId) {
            return _amount;
        }
        uint256 decimalsFrom = tokenList[_token].tokenDecimals[_fromChain];
        uint256 decimalsTo = tokenList[_token].decimals;
        if (decimalsFrom == decimalsTo) {
            return _amount;
        }
        return (_amount * (10 ** decimalsTo)) / (10 ** decimalsFrom);
    }

    function getVaultToken(address _token) external view override returns (address) {
        return tokenList[_token].vaultToken;
    }

    function getTokenFee(address _token, uint256 _amount, uint256 _toChain) external view override returns (uint256) {
        FeeRate memory feeRate = tokenList[_token].fees[_toChain];
        return _getFee(feeRate, _amount);
    }

    function getTransferFee(
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        uint256 _toChain
    ) external view override returns (uint256) {
        FeeRate memory feeRate = tokenList[_token].fees[_toChain];
        uint256 fee = _getFee(feeRate, _amount);
        FeeRate memory outFeeRate = tokenList[_token].outFees[_fromChain];
        uint256 fromChainFee = _getFee(outFeeRate, _amount);
        return fee > fromChainFee ? fee : fromChainFee;
    }

    function _getFee(FeeRate memory _feeRate, uint256 _amount) internal pure returns (uint256) {
        uint256 fee = (_amount * (_feeRate.rate)) / MAX_RATE_UNI;
        if (fee > _feeRate.highest) {
            return _feeRate.highest;
        } else if (fee < _feeRate.lowest) {
            return _feeRate.lowest;
        }
        return fee;
    }

    function getTargetTokenInfo(
        address _token,
        uint256 _chain
    )
        external
        view
        returns (bytes memory targetToken, uint8 decimals, FeeRate memory feeRate, FeeRate memory outFeeRate)
    {
        if (_chain == selfChainId) {
            targetToken = Utils.toBytes(_token);
            decimals = tokenList[_token].decimals;
        } else {
            targetToken = tokenList[_token].mappingTokens[_chain];
            decimals = tokenList[_token].tokenDecimals[_chain];
        }

        feeRate = tokenList[_token].fees[_chain];
        outFeeRate = tokenList[_token].outFees[_chain];
    }

    function getToChainTokenInfo(
        address _token,
        uint256 _toChain
    ) external view returns (bytes memory toChainToken, uint8 decimals, FeeRate memory feeRate) {
        if (_toChain == selfChainId) {
            toChainToken = Utils.toBytes(_token);
            decimals = tokenList[_token].decimals;
        } else {
            toChainToken = tokenList[_token].mappingTokens[_toChain];
            decimals = tokenList[_token].tokenDecimals[_toChain];
        }

        feeRate = tokenList[_token].fees[_toChain];
    }

    function getFeeAmountAndInfo(
        uint256 _fromChain,
        bytes memory _fromToken,
        uint256 _fromAmount,
        uint256 _toChain
    )
        external
        view
        returns (
            uint256 _feeAmount,
            FeeRate memory _feeRate,
            address _relayToken,
            uint8 _relayTokenDecimals,
            bytes memory _toToken,
            uint8 _toTokenDecimals
        )
    {
        (_relayToken, , _feeAmount) = this.getRelayFee(_fromChain, _fromToken, _fromAmount, _toChain);
        (_toToken, _toTokenDecimals, _feeRate) = this.getToChainTokenInfo(_relayToken, _toChain);

        _relayTokenDecimals = tokenList[_relayToken].decimals;
    }

    function getFeeAmountAndVaultBalance(
        uint256 _srcChain,
        bytes memory _srcToken,
        uint256 _srcAmount,
        uint256 _targetChain
    )
        external
        view
        returns (uint256 _srcFeeAmount, uint256 _relayChainAmount, int256 _vaultBalance, bytes memory _toChainToken)
    {
        address relayToken;
        uint256 feeAmount;

        (relayToken, _relayChainAmount, feeAmount) = this.getRelayFee(_srcChain, _srcToken, _srcAmount, _targetChain);
        _srcFeeAmount = this.getToChainAmount(relayToken, feeAmount, _srcChain);

        _vaultBalance = getVaultBalance(relayToken, _targetChain);

        _toChainToken = this.getToChainToken(relayToken, _targetChain);
    }

    // get source chain token amount and the fee amount based the target chain token amount
    function getSrcAmountAndFee(
        uint256 _targetChain,
        bytes memory _targetToken,
        uint256 _targetAmount,
        uint256 _srcChain
    )
        external
        view
        returns (uint256 _srcFeeAmount, uint256 _srcChainAmount, int256 _vaultBalance, bytes memory _srcChainToken)
    {
        address relayToken = this.getRelayChainToken(_targetChain, _targetToken);
        // TODO: require relay token?
        uint256 relayChainAmount = this.getRelayChainAmount(relayToken, _targetChain, _targetAmount);
        uint256 amountBeforeFee = _getAmountBeforeFee(relayToken, relayChainAmount, _targetChain, _srcChain);
        _srcFeeAmount = this.getToChainAmount(relayToken, (amountBeforeFee - relayChainAmount), _srcChain);
        _srcChainAmount = this.getToChainAmount(relayToken, amountBeforeFee, _srcChain);
        _srcChainToken = this.getToChainToken(relayToken, _srcChain);
        // TODO: require source token?
        _vaultBalance = getVaultBalance(relayToken, _targetAmount);
    }

    function _getAmountBeforeFee(
        address _token,
        uint256 _amount,
        uint256 _toChain,
        uint256 _fromChain
    ) internal view returns (uint256) {
        FeeRate memory feeRate = tokenList[_token].fees[_toChain];
        uint256 outAmount = _getBeforeAmount(feeRate, _amount);
        FeeRate memory fromChainFeeRate = tokenList[_token].outFees[_fromChain];
        uint256 fAmount = _getBeforeAmount(fromChainFeeRate, _amount);
        return outAmount > fAmount ? outAmount : fAmount;
    }

    function _getBeforeAmount(FeeRate memory feeRate, uint256 _amount) internal pure returns (uint256) {
        uint256 outAmount = (_amount * MAX_RATE_UNI) / (MAX_RATE_UNI - feeRate.rate);
        if (outAmount > _amount + (feeRate.highest)) {
            outAmount = _amount + (feeRate.highest);
        } else if (outAmount < _amount + (feeRate.lowest)) {
            outAmount = _amount + (feeRate.lowest);
        }
        return outAmount;
    }

    function getVaultBalance(address _token, uint256 _chainId) public view returns (int256 _vaultBalance) {
        address vault = this.getVaultToken(_token);
        (bool result, bytes memory data) = vault.staticcall(abi.encodeWithSignature("vaultBalance(uint256)", _chainId));
        if (result && data.length > 0) {
            _vaultBalance = abi.decode(data, (int256));
            if (_vaultBalance > 0) {
                uint256 tem = this.getToChainAmount(_token, uint256(_vaultBalance), _chainId);
                require(tem <= uint256(type(int256).max), "value doesn't fit in an int256");
                _vaultBalance = int256(tem);
            } else {
                _vaultBalance = 0;
            }
        } else {
            _vaultBalance = 0;
        }
    }

    // -----------------------------------------------------

    function getRelayFee(
        uint256 _fromChain,
        bytes memory _fromToken,
        uint256 _fromAmount,
        uint256 _toChain
    ) external view returns (address _relayToken, uint256 _relayChainAmount, uint256 _feeAmount) {
        _relayToken = this.getRelayChainToken(_fromChain, _fromToken);

        _relayChainAmount = this.getRelayChainAmount(_relayToken, _fromChain, _fromAmount);

        _feeAmount = this.getTransferFee(_relayToken, _relayChainAmount, _fromChain, _toChain);
    }

    /** UUPS *********************************************************/
    function _authorizeUpgrade(address) internal view override {
        require(hasRole(UPGRADER_ROLE, msg.sender), "TokenRegister: only Admin can upgrade");
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
