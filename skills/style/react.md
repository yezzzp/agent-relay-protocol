# Known failures: React reference

Code for the rows of `SKILL.md` §5, for React with shadcn/ui. Adapt the paths. The rule is the same in any stack: the behavior lives in the base component, so every screen gets it, and lint forbids going around it.

## Double submit: the base button waits for its action

Change the library's `Button` itself (for shadcn, `components/ui/button.tsx`), not a wrapper that screens may forget. When `onClick` returns a promise, the button stays disabled until it settles.

```tsx
function Button({ onClick, disabled, ...props }: React.ComponentProps<"button"> & VariantProps<typeof buttonVariants> & { asChild?: boolean }) {
  const [pending, setPending] = React.useState(false);
  const running = React.useRef(false);
  const handle = (e: React.MouseEvent<HTMLButtonElement>) => {
    if (running.current) return e.preventDefault();
    const result = onClick?.(e) as unknown;
    if (result instanceof Promise) {
      running.current = true;
      setPending(true);
      result.finally(() => { running.current = false; setPending(false); });
    }
  };
  return <Comp {...props} onClick={handle} disabled={disabled || pending} aria-busy={pending || undefined} />;
}
```

`running` is a ref, not only state: the second click of a double click can arrive before React re-renders the disabled attribute. A form's submit button gets the same guard from the form helper (`isSubmitting`). The API side is idempotent anyway (an operation id with a unique constraint): the button protects the user, the key protects the data.

If the shadcn CLI regenerates the file, the change is lost: keep it in a note at the top of the file and in the project's memory.

## Unbounded input: a default limit

```tsx
function Input({ maxLength = 200, ...props }: React.ComponentProps<"input">) {
  return <input maxLength={maxLength} {...props} />;
}
```

Same for `Textarea` (for example 2 000). A field that really needs more passes its own `maxLength`.

## Draft lost: one hook

```tsx
function useDraft<T>(key: string, initial: T) {
  const [value, setValue] = React.useState<T>(() => {
    try { const raw = sessionStorage.getItem(key); return raw ? (JSON.parse(raw) as T) : initial; } catch { return initial; }
  });
  React.useEffect(() => { sessionStorage.setItem(key, JSON.stringify(value)); }, [key, value]);
  const clear = () => { sessionStorage.removeItem(key); setValue(initial); };
  return [value, setValue, clear] as const;
}
```

Call `clear()` after a successful save and on an explicit "discard".

## Lint: no going around the base components

In the app's code (not in the component library folder):

```js
// eslint.config.mjs
{
  files: ["app/**/*.tsx", "components/**/*.tsx"],
  ignores: ["components/ui/**"],
  rules: {
    "no-alert": "error",
    "no-restricted-syntax": ["error",
      { selector: "JSXOpeningElement[name.name='button']", message: "Use <Button>: it blocks double submit." },
      { selector: "JSXOpeningElement[name.name='input']", message: "Use <Input>: it carries a length limit." },
      { selector: "JSXOpeningElement[name.name='textarea']", message: "Use <Textarea>: it carries a length limit." },
      { selector: "JSXOpeningElement[name.name='select']", message: "Use the project's select component." },
    ],
  },
}
```

Turning these on in an existing app shows every place that needs the shared component. Fix them in one pass, by class.
