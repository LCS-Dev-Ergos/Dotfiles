"""A scripted prompter: the person in a guided setup, for tests."""

from core.prompt import Cancelled, Prompter


class ScriptedPrompter(Prompter):
    """Answers from a script and fails the test on any other question.

    answers holds (kind, answer) pairs in the order the flow should ask:
    kind is confirm, choose or choose_many, and an answer of Cancelled
    leaves the flow as Esc or Ctrl-C would. attended=False stands for no
    terminal: a question then fails as the real prompter's does.
    """

    def __init__(self, test, answers=(), *, attended=True):
        self.test = test
        self.attended = attended
        self.answers = list(answers)
        self.asked = []

    def answer(self, kind, question, **details):
        self.asked.append((kind, question, details))
        if not self.attended:
            raise self.unattended(question, details["flag"])
        if not self.answers:
            self.test.fail(f"unexpected {kind}: {question}")
        expected, answer = self.answers.pop(0)
        self.test.assertEqual(kind, expected, question)
        if answer is Cancelled:
            raise Cancelled
        return answer

    def confirm(self, question, *, default=False, flag):
        return self.answer("confirm", question, default=default, flag=flag)

    def choose(self, header, options, *, default=None, flag):
        return self.answer(
            "choose", header, options=options, default=default, flag=flag
        )

    def choose_many(self, header, options, *, selected=(), flag):
        return self.answer(
            "choose_many",
            header,
            options=options,
            selected=list(selected),
            flag=flag,
        )

    def finished(self):
        """Every scripted answer was asked for."""
        self.test.assertEqual(self.answers, [], "unasked questions remain")
