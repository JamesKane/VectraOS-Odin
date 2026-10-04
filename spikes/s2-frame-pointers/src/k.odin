package k

@(export, link_name="kmain")
kmain :: proc "c" (n: int) -> int {
	return mid(n) + 1
}

mid :: proc "contextless" (a: int) -> int {
	return leaf(a) * 2
}

leaf :: proc "contextless" (a: int) -> int {
	return a * 3 + 1
}
