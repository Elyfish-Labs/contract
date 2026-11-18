// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title Elyfish Collection — rod and bobber skins of the game Elyfish (elyfish.xyz), one ERC-721 collection
/// @notice 10,000 unique tokens. Every skin owns a fixed block of token ids (its supply), so a token's skin, rarity
/// and serial number follow from its id alone and can never change ("Moon Katana #12 / 50"). The buyer picks the
/// skin; the price is set in US dollars per rarity and paid in the chain's native coin (HYPE) at the HYPE / USD rate
/// of a Chainlink price feed. The metadata (JSON + image) lives on the game's CDN: the look and the in-game bonus
/// there may be updated, which is announced to marketplaces with the ERC-4906 events.
/// The skins are not all on sale at once: they take turns. Time runs in rounds of `period` (one week) from the
/// launch, and in every round `perRound` skins (two) are on sale — in the first round one legendary and one epic, in the
/// rounds after it the others, two by two, in an order shuffled once when the collection is deployed. When a round
/// ends its two skins close and the next two open. Once every skin has had its round the order starts again, so a
/// skin that was not sold out comes back on sale. Nobody, the owner included, can change the order or the clock.
/// OpenSea: ERC-721 metadata (tokenURI), contractURI (ERC-7572), royalties (ERC-2981), metadata refresh (ERC-4906).
contract ElyfishSkins is ERC721, ERC2981, Ownable2Step, Pausable, ReentrancyGuard, IERC4906 {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 10_000;
    /// @notice most tokens one mint transaction makes (a paid mint, or the owner's reserve mint)
    uint256 public constant MAX_PER_TX = 20;
    /// @notice rarities 0 common · 1 uncommon · 2 rare · 3 epic · 4 legendary
    uint8 public constant RARITIES = 5;
    uint8 public constant ROD = 0;
    uint8 public constant BOBBER = 1;
    /// @notice royalties are capped at 10 %
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    /// @notice prices are in USD with 8 decimals ($1 = 1e8); none above $100,000
    uint256 public constant MAX_USD_PRICE = 100_000e8;
    /// @notice a price older than this can never be accepted, whatever maxStaleness says
    uint256 public constant MAX_STALENESS_CAP = 7 days;
    /// @notice the first round's two skins are one of each of these rarities
    uint8 public constant EPIC = 3;
    uint8 public constant LEGENDARY = 4;
    /// @notice the longest a round may last
    uint256 public constant MAX_PERIOD = 30 days;

    struct Skin {
        uint8 kind; // ROD / BOBBER
        uint8 rarity; // 0..4
        uint16 start; // its first token id
        uint16 supply; // how many tokens it has (ids start .. start + supply - 1)
        uint16 minted; // how many are minted so far (always the lowest ids of its block)
    }

    /// what a mint costs and when the skins open (one constructor argument)
    struct Sale {
        uint256[RARITIES] usd; // the price of one token per rarity, USD with 8 decimals
        uint64 launch; // when the first round starts, a Unix time (0 = now, at deployment)
        uint64 period; // how long a round lasts, in seconds (604,800 = one week)
        uint16 perRound; // how many skins are on sale in a round (2)
    }

    Skin[] private _skins;
    /// @notice minted so far, all skins together
    uint256 public totalSupply;
    /// @notice the price of one token of each rarity, USD with 8 decimals (0 = free)
    uint256[RARITIES] public usdPrice;
    AggregatorV3Interface public priceFeed;
    /// @notice the oldest HYPE / USD answer a mint accepts, in seconds
    uint256 public maxStaleness;
    string private _baseTokenURI;
    string private _contractURI;
    /// @notice when the first round starts (one legendary and one epic on sale)
    uint64 public immutable launch;
    /// @notice how long a round lasts, in seconds: its skins are on sale that long, then the next ones are
    uint64 public immutable period;
    /// @notice how many skins are on sale in a round
    uint256 public immutable perRound;
    /// @notice how many rounds it takes until every skin has been on sale once; then the order starts again
    uint64 public immutable cycle;
    /// @dev the skins in the order they go on sale, PER_ROUND a round — written once in the constructor, never again
    uint16[] private _order;
    /// @dev per skin: the round of the cycle it is on sale in
    uint16[] private _turn;

    event SkinsMinted(address indexed to, uint256 indexed skinId, uint256 firstTokenId, uint256 quantity, uint256 paid);
    event PriceSet(uint8 indexed rarity, uint256 usd);
    event PriceFeedSet(address indexed feed, uint256 maxStaleness);
    event BaseURISet(string uri);
    /// @dev ERC-7572: marketplaces re-read contractURI
    event ContractURIUpdated();
    event Withdrawn(address indexed to, uint256 amount);

    error BadSkins();
    error UnknownSkin(uint256 skinId);
    error BadQuantity(uint256 quantity);
    error SoldOut(uint256 skinId, uint256 left);
    error Underpaid(uint256 cost, uint256 sent);
    error BadPrice();
    error StalePrice(uint256 updatedAt);
    error BadFeed();
    error BadRarity(uint8 rarity);
    error PriceTooHigh(uint256 usd);
    error BadRoyalty();
    error ZeroAddress();
    error TransferFailed();
    error NotAToken(uint256 tokenId);
    error BadSchedule();
    error NotStarted();
    error NotOnSale(uint256 skinId);

    /// @param owner_ who manages the collection (prices, feed, metadata, funds)
    /// @param feed the HYPE / USD price feed (Chainlink, or MockPriceFeed on a testnet without one)
    /// @param maxStaleness_ the oldest feed answer accepted (seconds)
    /// @param baseURI_ the metadata folder, ending in "/" (token n → baseURI_ + n + ".json")
    /// @param contractURI_ the collection's own metadata (OpenSea)
    /// @param royaltyReceiver who gets the royalties of resales
    /// @param royaltyBps the royalty in basis points (at most MAX_ROYALTY_BPS)
    /// @param kinds per skin: ROD or BOBBER
    /// @param rarities per skin: 0..4
    /// @param supplies per skin: its number of tokens; all together exactly MAX_SUPPLY
    /// @param sale the prices per rarity and the release schedule (see Sale)
    constructor(
        address owner_,
        address feed,
        uint256 maxStaleness_,
        string memory baseURI_,
        string memory contractURI_,
        address royaltyReceiver,
        uint96 royaltyBps,
        uint8[] memory kinds,
        uint8[] memory rarities,
        uint16[] memory supplies,
        Sale memory sale
    ) ERC721("Elyfish", "ELYFISH") Ownable(owner_) {
        uint256 n = kinds.length;
        if (n == 0 || rarities.length != n || supplies.length != n) revert BadSkins();
        uint256 next = 1;
        for (uint256 i = 0; i < n; i++) {
            if (kinds[i] > BOBBER || rarities[i] >= RARITIES || supplies[i] == 0) revert BadSkins();
            // (next ≤ MAX_SUPPLY + 1 (checked below), fits 16 bits)
            // forge-lint: disable-next-line(unsafe-typecast)
            _skins.push(Skin({kind: kinds[i], rarity: rarities[i], start: uint16(next), supply: supplies[i], minted: 0}));
            next += supplies[i];
            if (next > MAX_SUPPLY + 1) revert BadSkins();
        }
        if (next != MAX_SUPPLY + 1) revert BadSkins();
        _setFeed(feed, maxStaleness_);
        for (uint8 r = 0; r < RARITIES; r++) _setPrice(r, sale.usd[r]);
        _setRoyalty(royaltyReceiver, royaltyBps);
        _baseTokenURI = baseURI_;
        _contractURI = contractURI_;
        if (sale.period == 0 || sale.period > MAX_PERIOD || sale.perRound == 0) revert BadSchedule();
        // (a timestamp fits 64 bits for the next 500 billion years)
        // forge-lint: disable-next-line(unsafe-typecast)
        if (sale.launch == 0) sale.launch = uint64(block.timestamp);
        launch = sale.launch;
        period = sale.period;
        perRound = sale.perRound;
        _shuffle(rarities, sale.perRound);
        // (at most 10,000 skins)
        // forge-lint: disable-next-line(unsafe-typecast)
        cycle = uint64((n + sale.perRound - 1) / sale.perRound);
    }

    /// @dev the order the skins go on sale in. All skins are shuffled (Fisher–Yates, seeded by the block this runs
    /// in); then a legendary is brought to the front and an epic next to it (the first of each in the shuffled
    /// order), so the first round is one legendary and one epic. _turn[skin] = the round of the cycle it is sold in
    /// (`each` skins a round).
    function _shuffle(uint8[] memory rarities, uint256 each) private {
        uint256 n = rarities.length;
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) order[i] = i;
        uint256 seed = uint256(keccak256(abi.encode(block.timestamp, block.prevrandao, address(this), launch)));
        for (uint256 j = n; j > 1; j--) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 k = seed % j;
            (order[k], order[j - 1]) = (order[j - 1], order[k]);
        }
        for (uint256 j = 0; j < n; j++) {
            if (rarities[order[j]] == LEGENDARY) {
                (order[0], order[j]) = (order[j], order[0]);
                break;
            }
        }
        for (uint256 j = 1; j < n; j++) {
            if (rarities[order[j]] == EPIC) {
                (order[1], order[j]) = (order[j], order[1]);
                break;
            }
        }
        for (uint256 i = 0; i < n; i++) _turn.push(0);
        for (uint256 j = 0; j < n; j++) {
            // (at most 10,000 skins: far inside 16 bits)
            // forge-lint: disable-next-line(unsafe-typecast)
            _order.push(uint16(order[j]));
            // forge-lint: disable-next-line(unsafe-typecast)
            _turn[order[j]] = uint16(j / each);
        }
    }

    // ------------------------------------------------------------------ minting

    /// @notice mint `quantity` tokens of one skin, paying in HYPE. Pay hypePrice(skinId, quantity) or a little more
    /// (the rate may move before the transaction lands): whatever is above the price comes back at once.
    function mint(uint256 skinId, uint256 quantity) external payable whenNotPaused nonReentrant {
        uint256 cost = hypePrice(skinId, quantity);
        if (msg.value < cost) revert Underpaid(cost, msg.value);
        uint256 first = _mintSkin(msg.sender, skinId, quantity);
        emit SkinsMinted(msg.sender, skinId, first, quantity, cost);
        if (msg.value > cost) _send(payable(msg.sender), msg.value - cost);
    }

    /// @notice the owner's free mint from the same supply (giveaways, prizes, the team) — only of the skins on sale
    function reserveMint(address to, uint256 skinId, uint256 quantity) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 first = _mintSkin(to, skinId, quantity);
        emit SkinsMinted(to, skinId, first, quantity, 0);
    }

    /// @notice what `quantity` tokens of this skin cost now, in HYPE (wei, 18 decimals), rounded up
    function hypePrice(uint256 skinId, uint256 quantity) public view returns (uint256) {
        if (quantity == 0 || quantity > MAX_PER_TX) revert BadQuantity(quantity);
        uint256 usd = usdPrice[_skin(skinId).rarity] * quantity;
        if (usd == 0) return 0;
        (uint256 rate, uint8 dec) = hypeUsd();
        // usd (8 decimals) / rate (dec decimals) HYPE, as wei: usd · 10^dec · 10^18 / (rate · 10^8)
        return Math.mulDiv(usd * 10 ** dec, 1e18, rate * 1e8, Math.Rounding.Ceil);
    }

    /// @notice the HYPE / USD rate from the feed, checked: positive, from a finished round, not too old
    function hypeUsd() public view returns (uint256 rate, uint8 dec) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (answeredInRound < roundId || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(updatedAt);
        }
        // (answer > 0 (checked above))
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), priceFeed.decimals());
    }

    function _mintSkin(address to, uint256 skinId, uint256 quantity) private returns (uint256 first) {
        if (quantity == 0 || quantity > MAX_PER_TX) revert BadQuantity(quantity);
        Skin storage s = _skin(skinId);
        if (!_onSale(skinId)) revert NotOnSale(skinId);
        uint256 left = uint256(s.supply) - s.minted;
        if (quantity > left) revert SoldOut(skinId, left);
        first = uint256(s.start) + s.minted;
        // (the counters move before any token goes out: a receiver contract called back finds them already right)
        // (quantity ≤ MAX_PER_TX)
        // forge-lint: disable-next-line(unsafe-typecast)
        s.minted += uint16(quantity);
        totalSupply += quantity;
        for (uint256 i = 0; i < quantity; i++) _safeMint(to, first + i);
    }

    // ------------------------------------------------------------------ reading

    /// @notice how many skins there are (rods first, then bobbers — see skin())
    function skinCount() external view returns (uint256) {
        return _skins.length;
    }

    /// @notice one skin: kind, rarity, its first token id, supply and how many are minted
    function skin(uint256 skinId) external view returns (Skin memory) {
        return _skin(skinId);
    }

    /// @notice every skin at once (the mint page reads them in one call)
    function allSkins() external view returns (Skin[] memory) {
        return _skins;
    }

    /// @notice the round the sale is in: 0 from the launch, one more each `period` (reverts before the launch)
    function round() public view returns (uint256) {
        if (block.timestamp < launch) revert NotStarted();
        return (block.timestamp - launch) / period;
    }

    /// @notice is this skin on sale now? (its round of the cycle is the one running)
    function isOpen(uint256 skinId) external view returns (bool) {
        _skin(skinId);
        return _onSale(skinId);
    }

    /// @notice the skins on sale now (none before the launch), and when this round ends and the next skins open
    function onSale() external view returns (uint256[] memory skinIds, uint256 closesAt) {
        if (block.timestamp < launch) return (new uint256[](0), launch);
        uint256 r = (block.timestamp - launch) / period;
        closesAt = uint256(launch) + (r + 1) * period;
        uint256 from = (r % cycle) * perRound;
        uint256 n = _order.length;
        uint256 to = from + perRound > n ? n : from + perRound;
        skinIds = new uint256[](to - from);
        for (uint256 i = from; i < to; i++) skinIds[i - from] = _order[i];
    }

    /// @notice tokens of this skin still to mint
    function remaining(uint256 skinId) external view returns (uint256) {
        Skin storage s = _skin(skinId);
        return uint256(s.supply) - s.minted;
    }

    /// @notice the skin a token id belongs to and its serial number within that skin (1 = the first) — fixed for
    /// every id 1..MAX_SUPPLY, minted or not
    function skinOfToken(uint256 tokenId) public view returns (uint256 skinId, uint256 serial) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert NotAToken(tokenId);
        uint256 lo = 0;
        uint256 hi = _skins.length - 1;
        while (lo < hi) {   // the last skin whose block starts at or before tokenId
            uint256 mid = (lo + hi + 1) / 2;
            if (_skins[mid].start <= tokenId) lo = mid;
            else hi = mid - 1;
        }
        return (lo, tokenId - _skins[lo].start + 1);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    /// @notice the collection's metadata (name, description, image, royalties) for marketplaces
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);   // (0x49064906: ERC-4906)
    }

    // ------------------------------------------------------------------ the owner

    function setPrice(uint8 rarity, uint256 usd) external onlyOwner {
        _setPrice(rarity, usd);
    }

    function setPriceFeed(address feed, uint256 maxStaleness_) external onlyOwner {
        _setFeed(feed, maxStaleness_);
    }

    /// @notice a new metadata folder (bump its version to get past caches): marketplaces refresh every token
    function setBaseURI(string calldata uri) external onlyOwner {
        _baseTokenURI = uri;
        emit BaseURISet(uri);
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice tell marketplaces these tokens' metadata changed (after updating the JSON on the CDN)
    function refreshMetadata(uint256 fromTokenId, uint256 toTokenId) external onlyOwner {
        if (fromTokenId == 0 || fromTokenId > toTokenId || toTokenId > MAX_SUPPLY) revert NotAToken(fromTokenId);
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        _setRoyalty(receiver, bps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice send everything the mints brought in to `to`
    function withdraw(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        emit Withdrawn(to, amount);
        _send(to, amount);
    }

    // ------------------------------------------------------------------ internals

    function _onSale(uint256 skinId) private view returns (bool) {
        if (block.timestamp < launch) return false;
        return ((block.timestamp - launch) / period) % cycle == _turn[skinId];
    }

    function _skin(uint256 skinId) private view returns (Skin storage) {
        if (skinId >= _skins.length) revert UnknownSkin(skinId);
        return _skins[skinId];
    }

    function _setPrice(uint8 rarity, uint256 usd) private {
        if (rarity >= RARITIES) revert BadRarity(rarity);
        if (usd > MAX_USD_PRICE) revert PriceTooHigh(usd);
        usdPrice[rarity] = usd;
        emit PriceSet(rarity, usd);
    }

    function _setFeed(address feed, uint256 maxStaleness_) private {
        if (feed == address(0) || maxStaleness_ == 0 || maxStaleness_ > MAX_STALENESS_CAP) revert BadFeed();
        if (AggregatorV3Interface(feed).decimals() > 18) revert BadFeed();
        priceFeed = AggregatorV3Interface(feed);
        maxStaleness = maxStaleness_;
        emit PriceFeedSet(feed, maxStaleness_);
    }

    function _setRoyalty(address receiver, uint96 bps) private {
        if (receiver == address(0) || bps > MAX_ROYALTY_BPS) revert BadRoyalty();
        _setDefaultRoyalty(receiver, bps);
    }

    function _send(address payable to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
