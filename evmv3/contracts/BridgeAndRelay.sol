// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./lib/Helper.sol";
import "./interface/IMOSV3.sol";
import "./interface/IVaultTokenV3.sol";
import "./abstract/BridgeAbstract.sol";
import "./interface/IMintableToken.sol";
import "./interface/ITokenRegisterV3.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IAdapter {
    function transferOut(
        uint256 toChain,
        bytes memory messageData,
        uint256 fromChain
    ) external payable returns (bytes32);
}

contract BridgeAndRelay is BridgeAbstract {
    using AddressUpgradeable for address;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Rate {
        address receiver;
        uint256 rate;
    }
    enum ChainType {
        NULL,
        EVM,
        NEAR,
        TON,
        SOLANA
    }

    mapping(uint256 => bytes) public bridges;
    mapping(uint256 => ChainType) public chainTypes;

    ITokenRegisterV3 public tokenRegister;
    //id : 0 VToken  1:relayer
    mapping(uint256 => Rate) public distributeRate;

    uint256 public adaptorChainId;
    address public adaptor;         // near adaptor

    event SetTokenRegister(address tokenRegister);
    event RegisterChain(uint256 chainId, bytes bridge, ChainType chainType);
    event SetAdaptor(uint256 chainId, address adptor);
    event SetDistributeRate(uint256 id, address to, uint256 rate);

    event DepositIn(
        uint256 indexed fromChain,
        address indexed token,
        bytes32 indexed orderId,
        bytes from,
        address to,
        uint256 amount
    );

    function setAdaptor(uint256 _chainId, address _adaptor) external onlyRole(MANAGER_ROLE) {
        adaptorChainId = _chainId;
        adaptor = _adaptor;
        emit SetAdaptor(_chainId, _adaptor);
    }

    function setTokenRegister(address _register) external onlyRole(MANAGER_ROLE) checkAddress(_register) {
        tokenRegister = ITokenRegisterV3(_register);
        emit SetTokenRegister(_register);
    }

    function registerChain(uint256[] calldata _chainIds, bytes[] calldata _addresses, ChainType _type) external onlyRole(MANAGER_ROLE) {
        uint256 len = _chainIds.length;
        require(len == _addresses.length, "length mismatching");
        for (uint256 i = 0; i < len; i++) {
            bridges[_chainIds[i]] = _addresses[i];
            chainTypes[_chainIds[i]] = _type;
            emit RegisterChain(_chainIds[i], _addresses[i], _type);
        }
    }

    function setDistributeRate(
        uint256 _id,
        address _to,
        uint256 _rate
    ) external onlyRole(MANAGER_ROLE) checkAddress(_to) {
        require(_id < 3, "Invalid rate id");

        distributeRate[_id] = Rate(_to, _rate);

        require(
            distributeRate[0].rate + distributeRate[1].rate + distributeRate[2].rate <= 1000000,
            "invalid rate value"
        );
        emit SetDistributeRate(_id, _to, _rate);
    }

    function withdraw(address _vaultToken, uint256 _vaultAmount) external whenNotPaused {
        require(_vaultToken != address(0), "vault token not registered");
        address token = IVaultTokenV3(_vaultToken).getTokenAddress();
        address vaultToken = tokenRegister.getVaultToken(token);
        require(_vaultToken == vaultToken, "Invalid vault token");
        uint256 amount = IVaultTokenV3(vaultToken).getTokenAmount(_vaultAmount);
        IVaultTokenV3(vaultToken).withdraw(selfChainId, _vaultAmount, msg.sender);
        _withdraw(token, msg.sender, amount);
    }

    function depositToken(
        address _token,
        address _to,
        uint256 _amount
    ) external payable override nonReentrant whenNotPaused {
        (address token, , ) = _tokenIn(selfChainId, _amount, _token, 0, false);
        _deposit(token, abi.encodePacked(msg.sender), _to, _amount, bytes32(""), selfChainId);
    }

    function swapOutToken(
        address _sender, // initiator address
        address _token, // src token
        bytes memory _to,
        uint256 _amount,
        uint256 _toChain, // target chain id
        bytes calldata _bridgeData
    ) external payable override nonReentrant whenNotPaused returns (bytes32 orderId) {
        require(_toChain != selfChainId, "Cannot swap to self chain");
        require(!_checkBytes(bridges[_toChain], bytes("")), "bridge not registered");

        SwapOutParam memory param;
        param.from = _sender;
        param.to = _to;
        param.toChain = _toChain;
        param.token = Helper._isNative(_token) ? wToken : _token;

        _checkBridgeable(param.token, param.toChain);
        _checkLimit(_amount, param.toChain, param.token);

        if (isOmniToken(param.token)) {
            param.gasLimit = _getBaseGas(_toChain, OutType.INTER_TRANSFER);
        } else {
            param.gasLimit = _getBaseGas(_toChain, OutType.SWAP);
        }
        if (_bridgeData.length != 0) {
            BridgeParam memory bridge = abi.decode(_bridgeData, (BridgeParam));
            param.gasLimit += bridge.gasLimit;
            param.refundAddress = bridge.refundAddress;
            param.swapData = bridge.swapData;
        }
        uint256 messageFee;
        (, , messageFee) = _tokenIn(param.toChain, _amount, _token, param.gasLimit, true);
        bytes memory toToken = tokenRegister.getToChainToken(param.token, param.toChain);
        require(!_checkBytes(toToken, bytes("")), "token not registered");
        if (isOmniToken(param.token)) {
            param.amount = _amount;
            orderId = _interTransferAndCall(param, bridges[param.toChain], messageFee);
        } else {
            orderId = _getOrderId(param.from, param.to, param.toChain);
            uint256 mapOutAmount;
            (mapOutAmount, param.amount) = _collectFee(param.token, _amount, selfChainId, param.toChain);
            _checkAndBurn(param.token, mapOutAmount);
            bytes memory payload = abi.encode(
                orderId,
                toToken,
                param.amount,
                param.to,
                abi.encodePacked(param.from),
                param.swapData
            );
            IMOSV3.MessageData memory messageData = IMOSV3.MessageData({
                relay: false,
                msgType: IMOSV3.MessageType.MESSAGE,
                target: bridges[param.toChain],
                payload: payload,
                gasLimit: param.gasLimit,
                value: 0
            });
            if (param.toChain == adaptorChainId) {
                IAdapter(adaptor).transferOut{value: messageFee}(
                    param.toChain,
                    abi.encode(messageData),
                    selfChainId
                );
            } else {
                mos.transferOut{value: messageFee}(param.toChain, abi.encode(messageData), Helper.ZERO_ADDRESS);
            }
            emit CollectFee(orderId, param.token, (_amount - mapOutAmount));
        }
        emit SwapOut(
            orderId,
            param.toChain,
            _token,
            _amount,
            param.from,
            msg.sender,
            param.to,
            toToken,
            param.gasLimit,
            messageFee
        );
    }

    function mapoExecute(
        uint256 _fromChain,
        uint256 _toChain,
        bytes calldata _fromAddress,
        bytes32 _orderId,
        bytes calldata _message
    ) external payable override nonReentrant checkOrder(_orderId) returns (bytes memory newMessage) {
        require(msg.sender == address(mos) || msg.sender == adaptor, "only mos");
        require(_checkBytes(_fromAddress, bridges[_fromChain]), "invalid from");
        OutType outType;
        bytes memory payload;
        (outType, payload) = abi.decode(_message, (OutType, bytes));
        if (outType == OutType.SWAP) {
            return _dealWithSwapOut(_orderId, _fromChain, _toChain, payload);
        } else {
            return _dealWithDeposit(_orderId, _fromChain, _toChain, payload);
        }
    }

    function getFee(uint256 _id, uint256 _amount) public view returns (uint256, address) {
        Rate memory rate = distributeRate[_id];
        return (((_amount * rate.rate) / 1000000), rate.receiver);
    }

    function _deposit(
        address _token,
        bytes memory _from,
        address _to,
        uint256 _amount,
        bytes32 _orderId,
        uint256 _fromChain
    ) internal {
        address vaultToken = tokenRegister.getVaultToken(_token);
        require(vaultToken != address(0), "vault token not registered");
        IVaultTokenV3(vaultToken).deposit(_fromChain, _amount, _to);
        emit DepositIn(_fromChain, _token, _orderId, _from, _to, _amount);
    }

    function _dealWithSwapOut(
        bytes32 orderId,
        uint256 fromChain,
        uint256 toChain,
        bytes memory payload
    ) private returns (bytes memory) {
        SwapInParam memory param;
        param.fromChain = fromChain;
        param.orderId = orderId;
        bytes memory token;
        bytes memory to;
        uint256 gasLimit;
        (gasLimit, token, param.amount, param.from, to, param.swapData) = abi.decode(
            payload,
            (uint256, bytes, uint256, bytes, bytes, bytes)
        );
        param.token = tokenRegister.getRelayChainToken(fromChain, token);
        require(param.token != address(0), "map token not registered");
        uint256 mapOutAmount;
        uint256 outAmount;
        {
            uint256 mapAmount = tokenRegister.getRelayChainAmount(param.token, fromChain, param.amount);
            _checkAndMint(param.token, mapAmount);
            (mapOutAmount, outAmount) = _collectFee(param.token, mapAmount, fromChain, toChain);
            emit CollectFee(orderId, param.token, (mapAmount - mapOutAmount));
        }
        if (toChain == selfChainId) {
            param.to = _fromBytes(to);
            param.amount = mapOutAmount;
            _swapIn(param);
            return bytes("");
        } else {
            IMOSV3.MessageData memory messageData;
            {
                bytes memory toToken = tokenRegister.getToChainToken(param.token, toChain);
                require(!_checkBytes(toToken, bytes("")), "Out token not registered");
                _checkAndBurn(param.token, mapOutAmount);
                bytes memory m = abi.encode(orderId, toToken, outAmount, to, param.from, param.swapData);
                messageData = IMOSV3.MessageData({
                    relay: true,
                    msgType: IMOSV3.MessageType.MESSAGE,
                    target: bridges[toChain],
                    payload: m,
                    gasLimit: gasLimit,
                    value: 0
                });
                emit Relay(orderId, orderId);
            }
            bytes memory payLoad = abi.encode(messageData);
            if (toChain == adaptorChainId) {
                // other chain -> mapo -> near
                // todo
                IAdapter(adaptor).transferOut(toChain, payLoad, fromChain);
                return bytes("");
            }
            if (fromChain == adaptorChainId) {
                // near -> mapo -> other chain
                //(uint256 msgFee, ) = mos.getMessageFee(toChain, address(0), gasLimit);
                bytes32 v3OrderId = mos.transferOut{value: msg.value}(toChain, payLoad, address(0));
                emit Relay(orderId, v3OrderId);
            }
            return payLoad;
        }
    }

    function _dealWithDeposit(
        bytes32 orderId,
        uint256 fromChain,
        uint256 toChain,
        bytes memory payload
    ) private returns (bytes memory) {
        require(selfChainId == toChain, "invalid chain");
        bytes memory token;
        uint256 amount;
        bytes memory from;
        address to;
        (token, amount, from, to) = abi.decode(payload, (bytes, uint256, bytes, address));
        address relayToken = tokenRegister.getRelayChainToken(fromChain, token);
        require(relayToken != address(0), "map token not registered");
        uint256 mapAmount = tokenRegister.getRelayChainAmount(relayToken, fromChain, amount);
        _checkAndMint(relayToken, mapAmount);
        _deposit(relayToken, from, to, mapAmount, orderId, fromChain);
        return bytes("");
    }

    function _collectFee(
        address _token,
        uint256 _mapAmount,
        uint256 _fromChain,
        uint256 _toChain
    ) private returns (uint256, uint256) {
        address token = _token;
        address vaultToken = tokenRegister.getVaultToken(token);
        require(vaultToken != address(0), "vault token not registered");
        uint256 fee = tokenRegister.getTransferFee(token, _mapAmount, _fromChain, _toChain);
        uint256 mapOutAmount = 0;
        uint256 outAmount = 0;
        if (_mapAmount > fee) {
            mapOutAmount = _mapAmount - fee;
            outAmount = tokenRegister.getToChainAmount(token, mapOutAmount, _toChain);
        } else {
            fee = _mapAmount;
        }
        uint256 otherFee = 0;
        if (fee > 0) {
            (uint256 vaultFee, ) = getFee(0, fee);
            otherFee = fee - vaultFee;

            (uint256 out, address receiver) = getFee(1, fee);
            if (out > 0 && receiver != address(0)) {
                _withdraw(token, receiver, out);
            }

            (uint256 protocolFee, address protocolReceiver) = getFee(2, fee);
            if (protocolFee > 0 && protocolReceiver != address(0)) {
                _withdraw(token, protocolReceiver, protocolFee);
            }
        }
        IVaultTokenV3(vaultToken).transferToken(_fromChain, _mapAmount, _toChain, mapOutAmount, selfChainId, otherFee);
        return (mapOutAmount, outAmount);
    }
}
