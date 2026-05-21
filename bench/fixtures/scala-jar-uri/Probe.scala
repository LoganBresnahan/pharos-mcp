//> using scala 3.3.3

object Probe {
  def main(args: Array[String]): Unit = {
    val xs: List[String] = List("a", "b", "c")
    val upper = xs.map(_.toUpperCase)
    println(upper)
  }
}
