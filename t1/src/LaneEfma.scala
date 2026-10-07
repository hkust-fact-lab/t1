// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 FACT Lab
//
// EFMA (nonlinear exp/log) VFU for T1.
//
// The EFMA datapath is SystemVerilog (`nl_nonlinear` and friends) and is
// vendored under `t1zaozi/vsrc/efma/`, which the t1 build already treats as
// the home of hand-written .sv implementations of fixed-IO modules.  Only the
// interface is declared in Chisel here; the body comes from that .sv file, so
// the datapath stays bit-identical to the EFMA copy used by wukong_rvv.

package org.chipsalliance.t1.rtl

import chisel3._
import chisel3.experimental.hierarchy.{instantiable, Instance, Instantiate}
import chisel3.experimental.{SerializableModule, SerializableModuleParameter}
import chisel3.properties.{Path, Property}
import chisel3.util._
import org.chipsalliance.stdlib.GeneralOM
import org.chipsalliance.t1.rtl.decoder.{BoolField, Decoder}

object LaneEfmaParam {
  implicit def rw: upickle.default.ReadWriter[LaneEfmaParam] = upickle.default.macroRW
}

case class LaneEfmaParam(datapathWidth: Int, latency: Int) extends VFUParameter with SerializableModuleParameter {
  val inputBundle             = new LaneEfmaRequest(datapathWidth)
  val decodeField: BoolField  = Decoder.efma
  val outputBundle            = new LaneEfmaResponse(datapathWidth)
  override val NeedSplit: Boolean = false
}

class LaneEfmaRequest(datapathWidth: Int) extends VFUPipeBundle {
  /** `src(0)` is the vs1 read (multiplier, drives `nl.b`) and `src(1)` is the vs2 read
    * (exponent operand, drives `nl.a`): the T1 lane builds `src` as (vs1, vs2, vd), and
    * `isVtype`/`Decoder.vtype` is what makes the lane read vs1 into `src(0)` at all.
    */
  val src:    Vec[UInt] = Vec(2, UInt(datapathWidth.W))
  val opcode: UInt      = UInt(4.W)
  val mask:   UInt      = UInt((datapathWidth / 8).W)
}

class LaneEfmaResponse(datapathWidth: Int) extends VFUPipeBundle {
  val data: UInt = UInt(datapathWidth.W)
}

class LaneEfmaOM(parameter: LaneEfmaParam) extends GeneralOM[LaneEfmaParam, LaneEfmaVFU](parameter) {
  override def hasRetime: Boolean = true
}

// Public FixedIOExtModule stub: the interface the hand-written .sv provides.
class LaneEfmaInterface(parameter: LaneEfmaParam) extends Bundle {
  val clock:      Clock                         = Input(Clock())
  val reset:      Bool                          = Input(Bool())
  val requestIO:  DecoupledIO[LaneEfmaRequest]  = Flipped(Decoupled(new LaneEfmaRequest(parameter.datapathWidth)))
  val responseIO: DecoupledIO[LaneEfmaResponse] = Decoupled(new LaneEfmaResponse(parameter.datapathWidth))
}

class LaneEfma(val parameter: LaneEfmaParam)
    extends FixedIOExtModule(new LaneEfmaInterface(parameter))
    with SerializableModule[LaneEfmaParam] {
  val paramDir = java.nio.file.Paths.get("zaozi-params")
  java.nio.file.Files.createDirectories(paramDir)
  java.nio.file.Files.write(
    paramDir.resolve("LaneEfma.json"),
    upickle.default.write(parameter).getBytes(java.nio.charset.StandardCharsets.UTF_8)
  )
}

// Internal VFU wrapper for Lane consumption.
@instantiable
class LaneEfmaVFU(val parameter: LaneEfmaParam) extends VFUModule with SerializableModule[LaneEfmaParam] {
  val omInstance: Instance[LaneEfmaOM] = Instantiate(new LaneEfmaOM(parameter))
  omInstance.retimeIn.foreach(_ := Property(Path(clock)))

  val impl = Module(new LaneEfma(parameter))
  impl.io.clock := clock
  impl.io.reset := reset.asBool

  impl.io.requestIO.valid := requestIO.valid
  requestIO.ready         := impl.io.requestIO.ready
  impl.io.requestIO.bits  := requestIO.bits.asTypeOf(impl.io.requestIO.bits)

  responseIO.valid         := impl.io.responseIO.valid
  impl.io.responseIO.ready := responseIO.ready
  responseIO.bits          := impl.io.responseIO.bits.asTypeOf(responseIO.bits)
}
