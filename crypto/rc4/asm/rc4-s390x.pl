#! /usr/bin/env perl
# Copyright 2009-2020 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

#
# ====================================================================
# Written by Andy Polyakov, @dot-asm, initially for use in the OpenSSL
# project. The module is, however, dual licensed under OpenSSL and
# CRYPTOGAMS licenses depending on where you obtain it. For further
# details see https://github.com/dot-asm/cryptogams/.
# ====================================================================
#
# February 2009
#
# Performance is 2x of gcc 3.4.6 on z10. Coding "secret" is to
# "cluster" Address Generation Interlocks, so that one pipeline stall
# resolves several dependencies.

# November 2010.
#
# Adapt for -m31 build. If kernel supports what's called "highgprs"
# feature on Linux [see /proc/cpuinfo], it's possible to use 64-bit
# instructions and achieve "64-bit" performance even in 31-bit legacy
# application context. The feature is not specific to any particular
# processor, as long as it's "z-CPU". Latter implies that the code
# remains z/Architecture specific. On z990 it was measured to perform
# 50% better than code generated by gcc 4.3.

# $output is the last argument if it looks like a file (it has an extension)
# $flavour is the first argument if it doesn't look like a file
$output = $#ARGV >= 0 && $ARGV[$#ARGV] =~ m|\.\w+$| ? pop : undef;
$flavour = $#ARGV >= 0 && $ARGV[0] !~ m|\.| ? shift : undef;

if ($flavour =~ /3[12]/) {
	$SIZE_T=4;
	$g="";
} else {
	$SIZE_T=8;
	$g="g";
}

$output and open STDOUT,">$output";

$rp="%r14";
$sp="%r15";
$code=<<___;
.text

___

# void RC4(RC4_KEY *key,size_t len,const void *inp,void *out)
{
$acc="%r0";
$cnt="%r1";
$key="%r2";
$len="%r3";
$inp="%r4";
$out="%r5";

@XX=("%r6","%r7");
@TX=("%r8","%r9");
$YY="%r10";
$TY="%r11";

$code.=<<___;
.globl	RC4
.type	RC4,\@function
.align	64
RC4:
	stm${g}	%r6,%r11,6*$SIZE_T($sp)
___
$code.=<<___ if ($flavour =~ /3[12]/);
	llgfr	$len,$len
___
$code.=<<___;
	llgc	$XX[0],0($key)
	llgc	$YY,1($key)
	la	$XX[0],1($XX[0])
	nill	$XX[0],0xff
	srlg	$cnt,$len,3
	ltgr	$cnt,$cnt
	llgc	$TX[0],2($XX[0],$key)
	jz	.Lshort
	j	.Loop8

.align	64
.Loop8:
___
for ($i=0;$i<8;$i++) {
$code.=<<___;
	la	$YY,0($YY,$TX[0])	# $i
	nill	$YY,255
	la	$XX[1],1($XX[0])
	nill	$XX[1],255
___
$code.=<<___ if ($i==1);
	llgc	$acc,2($TY,$key)
___
$code.=<<___ if ($i>1);
	sllg	$acc,$acc,8
	ic	$acc,2($TY,$key)
___
$code.=<<___;
	llgc	$TY,2($YY,$key)
	stc	$TX[0],2($YY,$key)
	llgc	$TX[1],2($XX[1],$key)
	stc	$TY,2($XX[0],$key)
	cr	$XX[1],$YY
	jne	.Lcmov$i
	la	$TX[1],0($TX[0])
.Lcmov$i:
	la	$TY,0($TY,$TX[0])
	nill	$TY,255
___
push(@TX,shift(@TX)); push(@XX,shift(@XX));     # "rotate" registers
}

$code.=<<___;
	lg	$TX[1],0($inp)
	sllg	$acc,$acc,8
	la	$inp,8($inp)
	ic	$acc,2($TY,$key)
	xgr	$acc,$TX[1]
	stg	$acc,0($out)
	la	$out,8($out)
	brctg	$cnt,.Loop8

.Lshort:
	lghi	$acc,7
	ngr	$len,$acc
	jz	.Lexit
	j	.Loop1

.align	16
.Loop1:
	la	$YY,0($YY,$TX[0])
	nill	$YY,255
	llgc	$TY,2($YY,$key)
	stc	$TX[0],2($YY,$key)
	stc	$TY,2($XX[0],$key)
	ar	$TY,$TX[0]
	ahi	$XX[0],1
	nill	$TY,255
	nill	$XX[0],255
	llgc	$acc,0($inp)
	la	$inp,1($inp)
	llgc	$TY,2($TY,$key)
	llgc	$TX[0],2($XX[0],$key)
	xr	$acc,$TY
	stc	$acc,0($out)
	la	$out,1($out)
	brct	$len,.Loop1

.Lexit:
	ahi	$XX[0],-1
	stc	$XX[0],0($key)
	stc	$YY,1($key)
	lm${g}	%r6,%r11,6*$SIZE_T($sp)
	br	$rp
.size	RC4,.-RC4
.string	"RC4 for s390x, CRYPTOGAMS by <https://github.com/dot-asm>"

___
}

# void RC4_set_key(RC4_KEY *key,unsigned int len,const void *inp)
{
$cnt="%r0";
$idx="%r1";
$key="%r2";
$len="%r3";
$inp="%r4";
$acc="%r5";
$dat="%r6";
$ikey="%r7";
$iinp="%r8";

$code.=<<___;
.globl	RC4_set_key
.type	RC4_set_key,\@function
.align	64
RC4_set_key:
	stm${g}	%r6,%r8,6*$SIZE_T($sp)
	lhi	$cnt,256
	la	$idx,0
	sth	$idx,0($key)
.align	4
.L1stloop:
	stc	$idx,2($idx,$key)
	la	$idx,1($idx)
	brct	$cnt,.L1stloop

	lghi	$ikey,-256
	lr	$cnt,$len
	la	$iinp,0
	la	$idx,0
.align	16
.L2ndloop:
	llgc	$acc,2+256($ikey,$key)
	llgc	$dat,0($iinp,$inp)
	la	$idx,0($idx,$acc)
	la	$ikey,1($ikey)
	la	$idx,0($idx,$dat)
	nill	$idx,255
	la	$iinp,1($iinp)
	tml	$ikey,255
	llgc	$dat,2($idx,$key)
	stc	$dat,2+256-1($ikey,$key)
	stc	$acc,2($idx,$key)
	jz	.Ldone
	brct	$cnt,.L2ndloop
	lr	$cnt,$len
	la	$iinp,0
	j	.L2ndloop
.Ldone:
	lm${g}	%r6,%r8,6*$SIZE_T($sp)
	br	$rp
.size	RC4_set_key,.-RC4_set_key

___
}

# const char *RC4_options()
$code.=<<___;
.globl	RC4_options
.type	RC4_options,\@function
.align	16
RC4_options:
	larl	%r2,.Loptions
	br	%r14
.size	RC4_options,.-RC4_options
.section	.rodata
.Loptions:
.align	8
.string	"rc4(8x,char)"
___

print $code;
close STDOUT or die "error closing STDOUT: $!";	# force flush
