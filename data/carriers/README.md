# Three-carrier public-access profile

`home-broadband-asns.tsv` is a conservative ASN-level approximation of public
subscriber access networks operated by China Telecom, China Unicom and China
Mobile. `home-broadband.txt` is the generated IPv4 prefix union used by the
firewall at runtime.

Selection policy:

- include carrier backbone, provincial access and MAN ASNs with material
  measured end-user populations;
- exclude AS names explicitly registered as IDC, cloud, CDN, IoT, 5G-only,
  industrial Internet, office or international/premium networks;
- explicitly exclude AS4809 (China Telecom CN2), AS9929 (China Unicom CUII)
  and AS58453 (China Mobile International);
- refresh the current prefixes from `ipverse/as-ip-blocks` without changing the
  curated ASN membership automatically.

Evidence sources:

- APNIC Whois registered `aut-num` records:
  <https://wq.apnic.net/static/search.html>
- APNIC Labs measured customer populations per AS:
  <https://stats.labs.apnic.net/cgi-bin/aspop?c=CN>
- Prefix source:
  <https://github.com/ipverse/as-ip-blocks>

This profile cannot prove that an individual address is residential. A carrier
can serve residential and non-residential customers from the same origin ASN.
The profile excludes separately originated enterprise/datacenter networks, but
mixed use inside an included ASN remains possible.
