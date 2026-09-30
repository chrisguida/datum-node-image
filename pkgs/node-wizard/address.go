package main

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"math/big"
	"strings"
)

// validateAddress accepts the address forms a coinbase output can pay on this
// chain (mainnet parameters): bech32 v0 (P2WPKH, P2WSH), bech32m v1+ (P2TR)
// and base58check P2PKH / P2SH.
func validateAddress(addr string) error {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return errors.New("empty")
	}
	if strings.HasPrefix(strings.ToLower(addr), "bc1") {
		return validateBech32(addr)
	}
	return validateBase58(addr)
}

const bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

const (
	bech32Const  = 1
	bech32mConst = 0x2bc830a3
)

func bech32Polymod(values []byte) uint32 {
	gen := [5]uint32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := uint32(1)
	for _, v := range values {
		top := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ uint32(v)
		for i := 0; i < 5; i++ {
			if (top>>uint(i))&1 == 1 {
				chk ^= gen[i]
			}
		}
	}
	return chk
}

func bech32HRPExpand(hrp string) []byte {
	out := make([]byte, 0, 2*len(hrp)+1)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]>>5)
	}
	out = append(out, 0)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]&31)
	}
	return out
}

func bech32Decode(s string) (hrp string, data []byte, encoding uint32, err error) {
	if strings.ToLower(s) != s && strings.ToUpper(s) != s {
		return "", nil, 0, errors.New("mixed case")
	}
	s = strings.ToLower(s)
	pos := strings.LastIndex(s, "1")
	if pos < 1 || pos+7 > len(s) || len(s) > 90 {
		return "", nil, 0, errors.New("bad format")
	}
	hrp = s[:pos]
	for i := 0; i < len(hrp); i++ {
		if hrp[i] < 33 || hrp[i] > 126 {
			return "", nil, 0, errors.New("bad hrp")
		}
	}
	data = make([]byte, 0, len(s)-pos-1)
	for _, c := range s[pos+1:] {
		i := strings.IndexRune(bech32Charset, c)
		if i < 0 {
			return "", nil, 0, errors.New("bad character")
		}
		data = append(data, byte(i))
	}
	chk := bech32Polymod(append(bech32HRPExpand(hrp), data...))
	if chk != bech32Const && chk != bech32mConst {
		return "", nil, 0, errors.New("bad checksum")
	}
	return hrp, data[:len(data)-6], chk, nil
}

func convertBits(data []byte, from, to uint, pad bool) ([]byte, error) {
	var acc uint32
	var bits uint
	out := []byte{}
	maxv := uint32(1)<<to - 1
	for _, v := range data {
		if uint32(v)>>from != 0 {
			return nil, errors.New("bad value")
		}
		acc = acc<<from | uint32(v)
		bits += from
		for bits >= to {
			bits -= to
			out = append(out, byte(acc>>bits&maxv))
		}
	}
	if pad {
		if bits > 0 {
			out = append(out, byte(acc<<(to-bits)&maxv))
		}
	} else if bits >= from || acc<<(to-bits)&maxv != 0 {
		return nil, errors.New("bad padding")
	}
	return out, nil
}

func validateBech32(addr string) error {
	hrp, data, enc, err := bech32Decode(addr)
	if err != nil {
		return err
	}
	if hrp != "bc" {
		return errors.New("wrong network")
	}
	if len(data) < 1 {
		return errors.New("empty program")
	}
	version := data[0]
	program, err := convertBits(data[1:], 5, 8, false)
	if err != nil {
		return err
	}
	switch {
	case version == 0:
		if enc != bech32Const {
			return errors.New("v0 must use bech32")
		}
		if len(program) != 20 && len(program) != 32 {
			return errors.New("bad v0 program length")
		}
	case version <= 16:
		if enc != bech32mConst {
			return errors.New("v1+ must use bech32m")
		}
		if len(program) < 2 || len(program) > 40 {
			return errors.New("bad program length")
		}
	default:
		return errors.New("bad witness version")
	}
	return nil
}

func validateBase58(addr string) error {
	const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
	n := new(big.Int)
	for _, c := range addr {
		i := strings.IndexRune(alphabet, c)
		if i < 0 {
			return errors.New("bad character")
		}
		n.Mul(n, big.NewInt(58))
		n.Add(n, big.NewInt(int64(i)))
	}
	b := n.Bytes()
	for i := 0; i < len(addr) && addr[i] == '1'; i++ {
		b = append([]byte{0}, b...)
	}
	if len(b) != 25 {
		return errors.New("bad length")
	}
	payload, chk := b[:21], b[21:]
	h1 := sha256.Sum256(payload)
	h2 := sha256.Sum256(h1[:])
	if !bytes.Equal(h2[:4], chk) {
		return errors.New("bad checksum")
	}
	if payload[0] != 0x00 && payload[0] != 0x05 {
		return errors.New("wrong network")
	}
	return nil
}
