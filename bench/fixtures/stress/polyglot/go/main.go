// Polyglot stress fixture — go side.
package main

import "fmt"

type PolyglotGoService struct {
	Label string
}

func (s PolyglotGoService) Render() string {
	return "go:" + s.Label
}

func MakeService(label string) PolyglotGoService {
	return PolyglotGoService{Label: label}
}

func main() {
	svc := MakeService("hello")
	fmt.Println(svc.Render())
}
