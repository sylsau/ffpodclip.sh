readme:
	./ffpodclip.sh --help | sed 's/EXAMPLE/EXAMPLE\n        See Example\/ directory for an example output./' > README
example:
	./ffpodclip.sh Example/example.m4a Example/example.png -q 25 -y -o Example/out_example.mp4
