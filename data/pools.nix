# DATUM pools on the BLAKE2b (BIP-110) chain, with their server public keys pinned.
#
# A pinned key is what makes the gateway refuse an impostor: the CONVOY build
# with an empty pool_pubkey accepts whatever key the far end presents. Every
# entry here was copied from the pool's own published connection page on the
# date noted; re-check before a release, keys can rotate.
{
  omegapool = {
    name = "OmegaPool";
    # iohzrd's pool (ratum backend). https://pool.iohzrd.tech/connect fills the
    # values from https://pool.iohzrd.tech/stats.json (.pool.datum_port, .pool.pubkey);
    # copied 2026-09-30, pool version 0.1.54, fee 0.5%.
    host = "pool.iohzrd.tech";
    port = 28915;
    pubkey = "e0af9254ca56f93666922eb268c57f3d62f0132eb6f204db0d3124efbe74fc58028496951ea1e68041986c274b66dedb9a8dfa689403757a7868084d4355bb63";
  };

  paperclip = {
    name = "Paperclip";
    # https://pool.paperclippool.xyz/ fills the values from /api/status
    # (.stats.pool.datum_port, .stats.pool.pubkey); copied 2026-09-30, 0% DATUM fee.
    host = "pool.paperclippool.xyz";
    port = 28915;
    pubkey = "eb9c7885044ca6dc7a4af3761cb739cbf88e88f6852e6c4b4f754710ec0cc8c9fb4a78cb35bbfe6ac4ec83feb0030e5e8ac065baf87d9ab21489011f3d865478";
  };

  convoy = {
    name = "CONVOY";
    # https://convoy.xyz/getstarted (2026-09-30)
    host = "datum-beta1.mine.convoy.xyz";
    port = 28915;
    pubkey = "dbb11fa0c2b5403e4f798fa6071bb97e6079d219598366032fdf2ae01962b13c5e66e2be7d6b008f0b2603f3e6f6fc64768fa786c8129c46d3e30a5867734b62";
  };

  alphapool = {
    name = "AlphaPool";
    # https://xbt.alphapool.tech/start (2026-09-25); requires the iohzrd gateway fork
    host = "us2.alphapool.tech";
    port = 28916;
    pubkey = "b831b2d6f1eaedb3da5b9e3702728edea0a32d6ce783a1452b2861c4d1b74d6b4c2ad5461bcf43485a6bac2cedf8da43d51164262ef6bcdb27f2242ada066d29";
  };

  rabid = {
    name = "Rabid Pool (PPLNS)";
    # https://pool.rabidmining.com/xbt#datum, PPLNS endpoint (2026-09-30);
    # their SOLO endpoint is port 28926 with a different key
    host = "xbt.rabidmining.com";
    port = 28916;
    pubkey = "9f41d02bfaf09d18d0db09711912a946ed2698c2f5507ab4f79a68655fb1f476e5127f60501b739eb6e89606bb0267f74750ebb55a75c7ef21434bf60ca66920";
  };

  rabid-solo = {
    name = "Rabid Pool (SOLO)";
    host = "xbt.rabidmining.com";
    port = 28926;
    pubkey = "c85f07849c41ace0673e61176f8e5984f3e7b1683227e76848f6e844800df3516096acbd2e99534d2380a07706ade2fc21278d4d975c4e99249573701cd57e6b";
  };

  # Not listed yet, keys still to be obtained from the operators:
  #   maveth   RIPTIDE, riptide.maveth.ca:29120 (0%); the page says to rely on the
  #            gateway's key auto-fetch and does not publish the key
  #   lazarus  AwokenLazarus; site unreachable on 2026-09-30
}
