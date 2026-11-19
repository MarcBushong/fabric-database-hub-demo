// The two accounts the app uses, side by side: Fabric (the data, as you) and GitHub (the Copilot chat).

import { Avatar, Button, Menu, MenuGroup, MenuGroupHeader, MenuItem, MenuList, MenuPopover, MenuTrigger, Spinner, Tooltip } from "@fluentui/react-components";
import { PersonCircle20Regular, PlugDisconnected20Regular, SignOut20Regular } from "@fluentui/react-icons";

import { useCopilotAccount } from "@/copilot/use-copilot";

export function AccountChips({ email, onSignOut }: { email: string | null; onSignOut: () => void }) {
    const github = useCopilotAccount();

    const githubChip =
        github.status === "signed-in" ? (
            <Menu>
                <MenuTrigger disableButtonEnhancement>
                    <Button appearance="subtle" size="small" className="account-chip" aria-label={`GitHub: ${github.login ?? "signed in"}${github.plan ? `, ${github.plan}` : ""}`}>
                        <Avatar size={20} name={github.login} image={github.avatarUrl ? { src: github.avatarUrl } : undefined} />
                        <span className="account-text">
                            <span>{github.login}</span>
                            {github.plan ? <small>{github.plan}</small> : null}
                        </span>
                    </Button>
                </MenuTrigger>
                <MenuPopover>
                    <MenuList>
                        <MenuGroup>
                            <MenuGroupHeader>GitHub, for Copilot</MenuGroupHeader>
                            <MenuItem icon={<SignOut20Regular />} onClick={github.signOut}>
                                Sign out of GitHub
                            </MenuItem>
                        </MenuGroup>
                    </MenuList>
                </MenuPopover>
            </Menu>
        ) : github.status === "signing-in" ? (
            <span className="account-chip muted">
                <Spinner size="extra-tiny" /> GitHub
            </span>
        ) : (
            <Tooltip content={github.status === "unavailable" ? (github.detail ?? "Copilot chat isn't connected.") : "Sign in to GitHub to chat with Copilot"} relationship="description" withArrow>
                <Button appearance="subtle" size="small" className={`account-chip${github.status === "unavailable" ? " muted" : ""}`} icon={github.status === "unavailable" ? <PlugDisconnected20Regular /> : <PersonCircle20Regular />} onClick={github.signIn}>
                    {github.status === "unavailable" ? "GitHub: not connected" : "Sign in to GitHub"}
                </Button>
            </Tooltip>
        );

    return (
        <div className="accounts" role="group" aria-label="Accounts">
            {githubChip}
            <Menu>
                <MenuTrigger disableButtonEnhancement>
                    <Button appearance="subtle" size="small" className="account-chip" aria-label={email ? `Fabric: ${email}` : "Fabric account"}>
                        <Avatar size={20} name={email ?? "Fabric"} color="colorful" />
                        <span className="account-text">
                            <span>{email ?? "Fabric"}</span>
                            <small>Fabric</small>
                        </span>
                    </Button>
                </MenuTrigger>
                <MenuPopover>
                    <MenuList>
                        <MenuGroup>
                            <MenuGroupHeader>{email ? `Fabric: ${email}` : "Fabric"}</MenuGroupHeader>
                            <MenuItem icon={<SignOut20Regular />} onClick={onSignOut}>
                                Sign out of the app
                            </MenuItem>
                        </MenuGroup>
                    </MenuList>
                </MenuPopover>
            </Menu>
        </div>
    );
}
