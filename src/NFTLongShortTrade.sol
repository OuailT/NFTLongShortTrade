// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/interface/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/ownable/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/draft-EIP712.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";


contract NFTLongShortTrade is EIP712("NFTLongShortTrade", "1"), Ownable, ReentrancyGuard {
    
    using SafeERC20 for IERC20;

    //***************************** ERROR ************/
    error ERR_NOT_ENOUGH_BALANCE;

    /**
        * @notice Details of the order.
        * @param sellerDeposit Amount deposited by the seller.
        * @param buyerCollateral Amount deposited by the buyer.
        * @param validity Timestamp representing the validity of the order.
        * @param expiry Timestamp representing the expiry of the order.
        * @param nonce Number used to verify the order's validity and prevent order reuse or duplication.
        * @param fee Fees applied to the order.
        * @param maker Address of the user creating the order.
        * @param paymentAsset Address of the ERC20 asset used for payment to the contract.
        * @param collection Address of the ERC712 collection associated with the order.
        * @param isBull Boolean indicating whether the maker is a "Bull".
    */
    struct Order {
        uint256 sellerDeposit;
        uint256 buyerCollateral; 
        uint256 validity; 
        uint256 expiry;
        uint256 nonce;
        uint16 fee; 
        address maker;
        address paymentAsset;
        address collection; 
        bool isBull;
    }

    uint256 public fee;


    /**
     * @notice Order type hash based on EIP712
     * @dev ORDER_TYPE_HASH ensure that any data being signed match this specific data structure
    */
    bytes32 public constant ORDER_TYPE_HASH = 
            keccak256("Order(uint256 sellerDeposit, uint256 buyerCollateral, uint256 validity, uint256 expiry, uint256 nonce, uint16 fee, address maker, address paymentAsset, address collection, bool isBull)"
    );

    /// @notice the amount of fee withdrawble by the owner
    mapping (address => uint256) public withdrawableFees;

    /// @notice Address of the seller for a contract
    mapping (uint256 => address) public sellers;

    /// @notice Address of the buyer for a contract
    mapping (uint256 => address) public buyers;

    /// @notice The address of WETH contract
    address payable public immutable weth;

    /// @notice To keep track all matched order
    mapping (uint256 => Order) public matchedOrders;

    // @notice the addresses of an allowed NFT collection 
    mapping (address => bool) public allowedCollection;

    // @notice the addresses of an allowed ERC20 tokens
    mapping (address => bool) public allowedTokens;
    

    /**
     * @param Order The initial Fee rate
     * @param _weth The address of WETH contract
    */
    constructor(uint256 _fee, address _weth) {
        weth = payable(_weth);
        setFee(_fee);
    }


    // TODO 1-Create a function matchedorder; [x]
    // 2-Hash the order by creating hash order function EIP712 [x]
    // 3- calculate the fee for both sellers and buyers [x]
    // 4- deteminte who is the maker of the order and who the taker using is Bull/maker [x]
    // 5- Calculate the fee for both maker and taker [x]
    // 6- Storage the value of the buyer and seller in mapping using the contractID/EIP712 hashed order; [x]
    // 7- Retrieve payment based on the the order.asset [x]
    // 8- Create struct to keep track of all the matched order. [x]
    // 9- Check if the signature is valid ??? (Include more conditions to check if the orderisValid); TO BE CONTINUED...

    /**
     * @notice Match the order with the maker
     * @param order the order created by the maker
     * @param _signature the hashed _signature of the order
     * @return contractId returns the contract id
    */
    function matchOrder(Order calldata order, bytes32 calldata _signature) external payable nonReentrant returns(uint256) {
            bytes32 hashedOrder = hashOrder(order);

            isValidOrder(order, hashedOrder, signature);
    
            // contractID to saves buyers and seller to mapping after orderMatch
            uint256 contractId = uint256(hashedOrder);

            uint256 sellerFees;
            uint256 buyerFees;
            
            /// @audit issue Cover Rounding issues
            if(fee > 0) {
                sellerFees = (order.sellerDeposit * fee) / 1000;
                buyerFees = (order.buyerCollateral * fee) / 1000;
                WithdrawableFees[order.paymentAsset] += sellerFees + buyerFees; 
            }

            address buyer;
            address seller;

            uint256 makerPrice;
            uint256 takerPrice;

            // Determine who is the maker of the order
            if(order.isBull) {
                buyer = order.maker;
                seller = msg.sender;

                // calculate the price must be deposited by both parties
                makerPrice = order.buyerCollateral + buyerFees;
                takerPrice = order.sellerDeposit + sellerFees;

            } else {
                buyer = msg.sender;
                seller = order.maker;

                // calculate the price must be deposited by both parties
                makerPrice = order.sellerDeposit + sellerFees;
                takerPrice = order.buyerCollateral + buyerFees;
                
            }

            seller[contractId] = seller;
            buyers[contractId] = buyer;

            matchedOrders[contractId] =  order;


            // Retrieve payment from the the order maker
            uint256 makerTokensBalance = IERC20(order.paymentAsset).balanceOf(order.maker);


            /// @audit note What if the maker want to deposit their eth 
            if(makerPrice > 0 && makerTokensBalance >= makerPrice) {
                IERC20(order.paymentAsset).safeTransferFrom(order.maker, address(this), makerPrice);
            } else  { revert ERR_NOT_ENOUGH_BALANCE(); }
             
            // Retrieve payment from the taker
            uint256 takerTokensBalance = IERC20(order.paymentAsset).balanceOf(msg.sender);

            if (takerPrice >= msg.value) {
                require(order.paymentAsset == weth, "Invalid payment asset");
                WETH(weth).deposit{value : msg.value}();
            } else if(takerPrice > 0 && takerTokensBalance >= takerPrice) {
                IERC20(order.paymentAsset).safeTransferFrom(msg.sender, address(this), takerPrice);
            } else { revert ERR_NOT_ENOUGH_BALANCE(); } 

        return contractId;                    

    }


    /** 
      * @notice Hashed the order according to EIP712  
      * @param order the struct order to hash
      * @return hashedOrder EIP721 hash of the order
    */  
    function hashOrder(Order calldata order) public returns(bytes32) {
         // abi.encode package all the input data with different types(string, uint) into bytes format then
        // hashing using keccak256 to get a unique hash
        bytes32 hashedOrder = keccak256(
                abi.encode(
                    ORDER_TYPE_HASH,
                    order.sellerDeposit,
                    order.buyerCollateral,
                    order.validity,
                    order.expiry,
                    order.none,
                    order.fee,
                    order.maker,
                    order.paymentAsset,
                    order.collection,
                    order.isBull
                )
            );
        
         // function returns the hash of the fully encoded EIP712 message for this domain
        return _hashTypedDataV4(hashedOrder);
    }   


    /**
     * @notice Sets new fee rate only by the owner
     * @param _fee The value of the new fee rate
    */
    function setFee(uint256 _fee) public onlyOwner {
        require(_fee < 50, "Fee cannot be more than 5%");
        fee = _fee;
    }

    
    /**
        * @notice Verify if an order is valid 
        * @param order the order to verify
        * @param _signature The signature corresponding to the EIP712 hashed order
    */
    function isValidOrder(Order memory order, bytes32 _hashOrder , bytes32 calldata _signature) public view {
        
        // Verify if the signature of a hashed order was made my the maker
        require(isValidSignature(order.maker, _hashOrder, _signature, "INVALID_SIGNATURE");

        // Verify if the order's timestamp is greater than validity
        require(block.timestamp >= validity, "EXPIRED_ORDER");

        // Verify if the fee set for an order are valid
        require(order.fee >= fee, "INVALID_FEE");

        // Verify if the order would be expired in the future
        require(order.expiry > order.validity, "INVALID_EXPIRY_TIME");

        // Veirify if the the NFT collection in valid
        require(allowedCollection[order.collection], "INVALID_COLLECTION");

        // Verify if the the payment asset are valid
        require(allowedTokens[order.paymentAsset], "INVALID_PAYMENTASSET");

        // Verify if the current order isn't matched order
        require(matchedOrder[uint256(_hashOrder)].maker == address(0), "ORDER_ALREADY_MATCHED");


    }

    /**
        * @notice Set an NFT collection by the owner
        * @param _collection The address of the NFT collection
        * @param _allowed Set to `true` if the collection is allowed, `false` otherwise
    */
     function setAllowedCollection(address _collection, bool _allowed) public onlyOwner {
            allowedCollection[_collection] = _allowed;
            // emit event
    }


    /**
        * @notice Set permission for using specific ERC20 tokens as a payment asset by the owner
        * @param _token The addresses of the tokens
        * @param _allowed Set to `true` if the tokens are allowed as a payment asset, `false` otherwise
    */
     function setAllowedCollection(address _token, bool _allowed) public onlyOwner {
            allowedTokens[_token] = _allowed;
            // emit event
    }

    
    /**
        * @notice Verify if the signature of an order hash was made by `_signer`
        * @param _signer The address of the signer
        * @param _signature The signature corresponding to the EIP712 hashed order
        * @param _hashOrder The EIP712 hash of the order
        * @return bool Returns `true` if the signature of the hashed order was made by the address of the `_signer`, otherwise `false`.
    */
    function isValidSignature(address _signer, bytes32 _hashOrder, bytes32 _signature) public pure view returns (bool) {
          ECDSA.recover(_hashOrder, _signature) == _signer;
    }



}