// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 Jiuyang Liu <liu@jiuyang.me>

package org.chipsalliance

/** Parse instructions from riscv/riscv-opcodes */
package object rvdecoderdb {
  def instructions(riscvOpcodes: os.Path, custom: Iterable[os.Path] = Seq.empty): Iterable[Instruction] = {
    parser.parse(
      os
        .walk(riscvOpcodes)
        .filter(f =>
          f.baseName.startsWith("rv128_") ||
            f.baseName.startsWith("rv64_") ||
            f.baseName.startsWith("rv32_") ||
            f.baseName.startsWith("rv_")
        )
        .filter(os.isFile)
        .map(f => (f.baseName, os.read(f), !f.segments.contains("unratified"), false)) ++
        custom
          .flatMap(p => {
            if (os.isFile(p)) {
              Seq((p.baseName, os.read(p), false, true))
            } else {
              os.walk(p).filter(os.isFile).map(f => (f.baseName, os.read(f), false, true))
            }
          }),
      argLut(riscvOpcodes).view.mapValues(a => (a.lsb, a.msb)).toMap
    )
  }

  def argLut(riscvOpcodes: os.Path): Map[String, Arg] = os
    .read(riscvOpcodes / "arg_lut.csv")
    .split("\n")
    .map { str =>
      val l = str
        .replace(", ", ",")
        .replace("\"", "")
        .split(",")
      l(0) -> Arg(l(0), l(1).toInt, l(2).toInt)
    }
    .toMap

  def causes(riscvOpcodes: os.Path): Map[String, Int] = os
    .read(riscvOpcodes / "causes.csv")
    .split("\n")
    .map { str =>
      val l = str
        .replace(", ", ",")
        .replace("\"", "")
        .split(",")
      l(1) -> java.lang.Long.decode(l(0)).toInt
    }
    .toMap

  def csrs(riscvOpcodes: os.Path): Seq[(String, Int)] =
    Seq(os.read(riscvOpcodes / "csrs.csv"), os.read(riscvOpcodes / "csrs32.csv")).flatMap(
      _.split("\n")
        .map { str =>
          val l = str
            .replace(" ", "")
            .replace("\"", "")
            .replace("\'", "")
            .split(",")
          l(1) -> java.lang.Long.decode(l(0)).toInt
        }
        .toMap
    )

  /** Copy a classpath resource to a real file.

    *

    * `os.resource` only yields a usable path when the classpath entry is a directory;

    * when the elaborator runs from a jar (nix `share/java/elaborator.jar`) it cannot be

    * read that way, so read the bytes through the stream instead.

    */

  private def copyResource(cl: ClassLoader, name: String, dest: os.Path): Unit = {

    val is = cl.getResourceAsStream(name)

    require(is != null, s"classpath resource not found: $name")

    try os.write.over(dest, is.readAllBytes())

    finally is.close()

  }


  def extractResource(cl: ClassLoader): os.Path = {
    val rvdecoderdbPath = os.temp.dir()
    // The tar must NOT live inside rvdecoderdbPath: the custom-resource branch walks
    // its directory without a name filter, so a stray .tar there would be parsed as an
    // opcode file (binary "lines" -> no encoding tokens -> empty.reduceLeft crash).
    val rvdecoderdbTar  = os.temp()
    copyResource(cl, "riscv-opcodes.tar", rvdecoderdbTar)
    os.proc("tar", "xf", rvdecoderdbTar).call(rvdecoderdbPath)
    rvdecoderdbPath
  }

  def extractCustomResource(cl: ClassLoader): os.Path = {
    val rvdecoderdbPath = os.temp.dir()
    val rvdecoderdbTar  = os.temp()
    copyResource(cl, "riscv-custom-opcodes.tar", rvdecoderdbTar)
    os.proc("tar", "xf", rvdecoderdbTar).call(rvdecoderdbPath)
    rvdecoderdbPath
  }

  @deprecated("remove fromFile")
  object fromFile {
    def instructions(riscvOpcodes: os.Path, custom: Iterable[os.Path] = Seq.empty): Iterable[Instruction] =
      rvdecoderdb.instructions(riscvOpcodes, custom)
    def argLut(riscvOpcodes: os.Path):                                              Map[String, Arg]      = rvdecoderdb.argLut(riscvOpcodes)
    def causes(riscvOpcodes: os.Path):                                              Map[String, Int]      = rvdecoderdb.causes(riscvOpcodes)
    def csrs(riscvOpcodes:   os.Path):                                              Seq[(String, Int)]    = rvdecoderdb.csrs(riscvOpcodes)
  }
}
